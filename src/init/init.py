import os
import json
import random
import shutil
import argparse

def create_json(numNodes):
    """
    Function that creates all the json files
    """
    if not("config_files" in os.listdir(".")):
        os.mkdir("./config_files")
    else:
        shutil.rmtree("./config_files")
        os.mkdir("./config_files")
    
    for i in range(1, numNodes+1):
        dictionary = {
            "id" : i,
            "edges" : [],
            "mst": []
        }

        with open(f'./config_files/node_{i}.json', "w") as f:
            f.write(json.dumps(dictionary))
    
    print("All json files created!")
        
def checkEdge(nodeA, nodeB):
    """
    Function that checks if already exists an edge from A to B
    """
    with open(f'./config_files/node_{nodeA}.json', "r") as f:
        a_edges = json.load(f)["edges"]
    
    for e in a_edges:
        if e[0] == nodeB:
            return True
    
    return False

def writeEdge(nodeA, nodeB, band):
    """
    Function that add a new edge in the json files
    """
    with open(f'./config_files/node_{nodeA}.json', "r") as f:
        data = json.load(f)
    
    data["edges"].append([nodeB, band])

    with open(f'./config_files/node_{nodeA}.json', "w") as f:
        json.dump(data, f)
    
    with open(f'./config_files/node_{nodeB}.json', "r") as f:
        data = json.load(f)
    
    data["edges"].append([nodeA, band])

    with open(f'./config_files/node_{nodeB}.json', "w") as f:
        json.dump(data, f)

def checkOneForAll(numNodes):
    """
    Function that check that all the peer are connected with at least one peer
    """
    for i in range(1, numNodes+1):
        with open(f'./config_files/node_{i}.json', "r") as f:
            a_edges = json.load(f)["edges"]
        if a_edges == []:
            b = i
            while b == i:
                b = random.randint(1, numNodes)
            band = random.randint(5, 100)
            writeEdge(i, b, band)

def create_edges(numEdges, numNodes):
    """
    Function that create the edges
    """
    i = 0
    while i != numEdges:
        a,b = 0, 0
        while a == b:
            a = random.randint(1, numNodes)
            b = random.randint(1, numNodes)
        if not checkEdge(a,b):
            band = random.randint(5, 100)
            writeEdge(a, b, band)
            i += 1 
    
    checkOneForAll(numNodes)
    print("All edges created!")

if __name__ == "__main__":

    parser = argparse.ArgumentParser(
        prog="P2PNetworkInit",
        description="Static initialization of P2P network"
        )
    
    parser.add_argument('-n', '--numNodes', default=10, type=int, help='Insert the number of peer of the network')
    parser.add_argument('-e', '--edges', choices=range(1, 101), default=80, type=int, help='Insert the percentage of edges that there w.r.t. the maximum number which is N*(N-1)/2')

    args = parser.parse_args()

    create_json(args.numNodes)

    maxNumEdges = int(args.numNodes * (args.numNodes - 1) / 2)
    numEdges = int(maxNumEdges / 100 * args.edges)

    create_edges(numEdges=numEdges, numNodes=args.numNodes)

    
    

