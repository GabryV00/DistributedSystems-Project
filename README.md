# Peer-to-Peer Streaming App

This repository contains the code and documentation of a simple streaming system, based on a Peer-to-Peer network, created as a project for the Distributed Systems exam.

The main feature that the system wants to implement is to guarantee that each communication takes place using the best available channel, i.e. the channel with the greatest minimum bandwidth.

This problem, in the graph domain, is known as the Widest Path Problem, which can be solved by calculating the Maximum Spanning Tree. Wanting to develop a distributed application, such as a real streaming system, to solve this problem, we used a slightly modified version of the Gallagher- Humblet-Spira algorithm.

The complete project report is available in the appropriate folder. It contains requirements analysis, system design, system implementation, system validation and future developments.

## How to use it

To run the system with minimal effort, first install the essential tools which are:
- Erlang
- Rebar3 (Erlang build system)
- Python
- Pip

Then, you can install the needed dependencies executing the following command:
```console
pip install -r src/webgui/requirements.txt 
```

At this point the wrapper scripts \texttt{`launch_p2p.sh`} and \texttt{`launch_server.sh`} can be executed from two different terminals to start respectively the Erlang backend and the Python web application.