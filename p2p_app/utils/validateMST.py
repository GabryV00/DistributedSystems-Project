import os
import json
import shutil
import networkx as nx

def calculate_maximum_spanning_tree(graph):
    # Remove duplicate edges
    graph = nx.Graph(graph)  # Ensure we're working with a new instance
    #graph.remove_edges_from(graph.selfloop_edges())  # Remove self-loops (if any)

    # Compute the Maximum Spanning Tree (MST)
    mst = nx.maximum_spanning_tree(graph)
    return mst

def create_files(mst):
    if not("validate_files" in os.listdir(".")):
        os.mkdir("./validate_files")
    else:
        shutil.rmtree("./validate_files")
        os.mkdir("./validate_files")
    
    for edges in mst.edges(data=True):
        idA = edges[0]
        idB = edges[1]
        w = edges[2]['weight']
        if not(f'node_{idA}.json' in os.listdir("./validate_files")):
            dict = {
                "id" : idA,
                "edges" : [[idB, w]]
            }
            with open(f'./validate_files/node_{idA}.json', "w") as f:
                f.write(json.dumps(dict))
        else:
            with open(f'./validate_files/node_{idA}.json', "r") as f:
                data = json.load(f)
    
            data["edges"].append([idB, w])

            with open(f'./validate_files/node_{idA}.json', "w") as f:
                json.dump(data, f)

        if not(f'node_{idB}.json' in os.listdir("./validate_files")):
            dict = {
                "id" : idB,
                "edges" : [[idA, w]]
            }
            with open(f'./validate_files/node_{idB}.json', "w") as f:
                f.write(json.dumps(dict))
        else:
            with open(f'./validate_files/node_{idB}.json', "r") as f:
                data = json.load(f)
    
            data["edges"].append([idA, w])

            with open(f'./validate_files/node_{idB}.json', "w") as f:
                json.dump(data, f)

def check_correctness(path_dist, path_centr):
    for node in os.listdir(path_dist):
        with open(f'{path_dist}/{node}', "r") as f:
                edges_dist = json.load(f)["mst"]
        with open(f'{path_centr}/{node}', "r") as f:
                edges_centr = json.load(f)["edges"]

        for e in edges_dist:
            if e in edges_centr:
                edges_centr.remove(e)
            else:
                return False
        if len(edges_centr) != 0:
            return False
    
    return True




if __name__ == "__main__":
    # Create an example graph with duplicate edges
    PATH_DIST = "./../../src/init/config_files"
    PATH_CENTR = "./validate_files"
    G = nx.Graph()

    nodes = os.listdir(PATH_DIST)
    for n in range(len(nodes)):
        id = nodes[n][5: len(nodes[n])-5]
        G.add_node(int(f'{id}'))
    
    for f in nodes:
        id_a = f[5: len(f)-5]
        with open(f'{PATH_DIST}/{f}', "r") as fl:
            edges = json.load(fl)["edges"]
        for n in edges:
            G.add_weighted_edges_from([(int(f'{id_a}'), int(f'{n[0]}'), int(f'{n[1]}'))])

    # Calculate Maximum Spanning Tree
    mst = calculate_maximum_spanning_tree(G)
    
    create_files(mst)
    print(check_correctness(PATH_CENTR, PATH_DIST))