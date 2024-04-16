#!/bin/bash

cd src/init
if [ $# -eq 0 ];
then
  python3 init.py
  echo "Network created with 10 nodes and 80% of density (standard parameters)!"
else
  python3 init.py -n $1 -e $2
  echo "Network created with $1 nodes and $2% of density!"
fi


cd ..
cd ..
cd p2p_app

[ -f "logs/log.txt" ] && rm logs/log.txt

rebar3 escriptize
_build/default/bin/p2p -v -i "../src/init/config_files/"

echo "Erlang app launched!"
