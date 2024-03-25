import os
import json
import argparse

def create_json(numNodes):
    
    if not("config_files" in os.listdir(".")):
        os.mkdir("./config_files")
    
    for i in range(1, numNodes+1):
        dictionary = {
            "id" : i,
            "edges" : []
        }

        with open(f'./config_files/node_{i}.json', "w") as f:
            f.write(json.dumps(dictionary))
        



if __name__ == "__main__":

    parser = argparse.ArgumentParser(
        prog="P2PNetworkInit",
        description="Static initialization of P2P network"
        )
    
    parser.add_argument('-n', '--numNodes', default=10, type=int, help='Insert the number of peer of the network')
    parser.add_argument('-e', '--edges', choices=range(1, 101), default=80, type=int, help='Insert the percentage of edges that there w.r.t. the maximum number which is N*(N-1)/2')

    args = parser.parse_args()

    create_json(args.numNodes)
    
    

