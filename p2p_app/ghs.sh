rebar3 escriptize && 

echo &&
echo Executing erlang script and logging events... &&
_build/default/bin/ghs &&
cp json/events.json ../Manim\ concurrent\ events/ghs/events.json &&
cd ../Manim\ concurrent\ events &&

echo &&
echo Rendering animation of events... &&
make ghs &&
cd ../GHS-Erlang 
