-module(asynch_write).
-export([init/1, init/4, write/1, stop/0]).


% EXAMPLES OF USE:
%
% c(asynch_write)                   			compile
%
% asynch_write:init("log.txt")                  create the file log.txt and start the asynch_write server
% asynch_write:write("Hello")					write "Hello" on the file
% asynch_write:stop()                           stop the asynch_write server and close the file


init(Filename) -> init(Filename, "", "", "").

init(Filename, Header, Separator, Footer) ->
    {ok, FileHandle} = file:open(Filename, [write]),
	LoggerId = spawn_link(fun () -> loop(FileHandle, Header, Separator, Footer, true) end),
	register(aynch_log, LoggerId),
	ok.


write(Binary) when is_binary(Binary) -> 
	String = binary_to_list(Binary),
	aynch_log ! {write, String}, 
	ok;

write(String) when is_list(String) -> 
	aynch_log ! {write, String}, 
	ok.


stop() -> 
	Ref = make_ref(),
	aynch_log ! {stop, self(), Ref},
	receive 
		{ack, Ref} -> ok 
	end,
	ok.



% RESERVED

loop(FileHandle, Header, Separator, Footer, FirstLog) ->
	receive
		{write, String} -> 
			case FirstLog of
				true -> SepString = Header ++ String;
				false -> SepString = Separator ++ String
			end,
			ok = file:write(FileHandle, SepString),
			loop(FileHandle, Header, Separator, Footer, false);
		{stop, Pid, Ref} -> 
			ok = file:write(FileHandle, Footer),
			file:close(FileHandle),
			Pid ! {ack, Ref}
	end,
	ok.
