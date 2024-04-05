import os
import json
import networkx as nx

def calculate_maximum_spanning_tree(graph):
    # Remove duplicate edges
    graph = nx.Graph(graph)  # Ensure we're working with a new instance
    #graph.remove_edges_from(graph.selfloop_edges())  # Remove self-loops (if any)

    # Compute the Maximum Spanning Tree (MST)
    mst = nx.maximum_spanning_tree(graph)
    return mst


if __name__ == "__main__":
    # Create an example graph with duplicate edges
    PATH = "./../../src/init/config_files"
    G = nx.Graph()

    nodes = os.listdir(PATH)
    for n in range(len(nodes)):
        id = nodes[n][5: len(nodes[n])-5]
        G.add_node(int(f'{id}'))
    
    for f in nodes:
        id_a = f[5: len(f)-5]
        with open(f'{PATH}/{f}', "r") as fl:
            edges = json.load(fl)["edges"]
        for n in edges:
            G.add_weighted_edges_from([(int(f'{id_a}'), int(f'{n[0]}'), int(f'{n[1]}'))])

    # Calculate Maximum Spanning Tree
    mst = calculate_maximum_spanning_tree(G)
    
    # Print edges of Maximum Spanning Tree
    print("Edges of Maximum Spanning Tree:")
    for edge in mst.edges(data=True):
        print(edge)