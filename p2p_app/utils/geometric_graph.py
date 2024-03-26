import math
import json
import time
import argparse
import networkx as nx
import matplotlib.pyplot as plt


def euclidean_distance(u, v):
    return math.sqrt(sum((a - b) ** 2 for a, b in zip(u, v)))


def generate(num_nodes):
    graph = nx.random_geometric_graph(num_nodes, 0.3, seed=int(time.time()))
    pos = nx.get_node_attributes(graph, 'pos')

    for u, v in graph.edges():
        graph[u][v]['weight'] = euclidean_distance(pos[u], pos[v])
    
    return graph


def export(graph, filename):
    pos = nx.get_node_attributes(graph, 'pos')
    data = {"nodes": [(v, (pos[v][0] * 7, pos[v][1] * 4)) for v in graph.nodes], \
            "edges": [(u, v, graph[u][v]['weight']) for (u,v) in graph.edges]}

    with open(filename, "w") as json_file:
        json.dump(data, json_file, indent=2)


def show(graph):
    pos = nx.get_node_attributes(graph, 'pos')
    nx.draw_networkx(graph, pos=pos, node_size=10, with_labels=False)
    plt.show()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate a random geometric graph with weights and export it to JSON.")
    parser.add_argument("-n", "--num_nodes", type=int, default=30, help="Number of nodes in the graph")
    parser.add_argument("-o", "--output_file", type=str, default="json/graph.json", help="Path to JSON output")
    parser.add_argument("-q", "--quiet", action='store_true', help="Do not show the graph")
    args = parser.parse_args()

    graph = generate(args.num_nodes)
    export(graph, args.output_file)
    if not args.quiet:
        show(graph)
