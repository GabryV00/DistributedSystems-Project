import os
import time
import json
import socket
import graphviz
from utils import string_to_list
from flask import Flask, render_template, send_file, request

app = Flask(__name__, template_folder="templates")

ADMIN_PORT = 9000
PEER_PORT = 9001
TCP_ADDR = "127.0.0.1"

LOG_FILE_NAME = '../../p2p_app/logs/log.txt'

def open_conn(id_peerA, id_peerB, band):
    """
    Function that send the request for opening a connection between PeerA and PeerB, with a specific bandwidth
    """
    #Open the socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((TCP_ADDR, PEER_PORT))
    dictionary = {
            "type": "req_conn",
            "idA" : id_peerA,
            "idB" : id_peerB,
            "band" : band
        }
    s.sendall(json.dumps(dictionary).encode())
    data = s.recv(1024)
    s.close()
    
    if b"ACK" in data:
        return True
    else:
        return False

def close_conn(id_peerA, id_peerB):
    """
    Function that send the request for closing a connection between PeerA and PeerB, if already exists
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((TCP_ADDR, PEER_PORT))
    dictionary = {
            "type": "close_conn",
            "idA" : id_peerA,
            "idB" : id_peerB
        }
    s.sendall(json.dumps(dictionary).encode())
    s.recv(1024)
    s.close()

def send_new(id_peer, edges):
    """
    Function that send the request for adding a new peer with the given edges
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((TCP_ADDR, ADMIN_PORT))
    dictionary = {
            "type": "new_peer",
            "id" : id_peer,
            "edges" : string_to_list(edges)
        }
    s.sendall(json.dumps(dictionary).encode())
    data = s.recv(1024)
    s.close()

def send_kill(id_peer):
    """
    Function that kills a specific Peer
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((TCP_ADDR, ADMIN_PORT))
    dictionary = {
            "type": "rem_peer",
            "id" : id_peer
        }
    s.sendall(json.dumps(dictionary).encode())
    data = s.recv(1024)
    s.close()

def generate_graph(PATH):
    """
    Function that generates the graph of the newtork reading the json files
    """
    if not("static" in os.listdir(".")):
        os.mkdir("./static")
    
    g = graphviz.Graph("P2P Streaming Network", strict=True, format='png')
    g.attr('node', shape='circle')
    nodes = os.listdir(PATH)
    for n in range(len(nodes)):
        id = nodes[n][5: len(nodes[n])-5]
        g.node(f'{id}', f'Peer {id}', color='red')
    
    for f in nodes:
        id_a = f[5: len(f)-5]
        with open(f'{PATH}/{f}', "r") as fl:
            edges = json.load(fl)["edges"]
            #edges_mst = json.load(fl)["mst"]
        for n in edges:
            g.edge(f'{id_a}', f'{n[0]}', label=f'{n[1]}', color='blue')
        #for n in edges_mst:
        #    g.edge(f'{id_a}', f'{n[0]}', label=f'{n[1]}', color='green')

    g.render('./static/graph.gv').replace('\\', '/')

#----------------------ADMIN---------------------------------

@app.route("/", methods=['GET', 'POST'])
def admin():
    generate_graph("./../init/config_files")
    with open(LOG_FILE_NAME, 'r') as file:
        content = file.read()
    return render_template('admin.html', content=content)

@app.route('/add_node', methods=['POST'])
def add_node():
    node_id = request.form['id']
    edges = request.form['edges']
    print(f'NodeID: {node_id}\nEdges:{edges}')
    
    send_new(node_id, edges)
    generate_graph("./../init/config_files")
    with open(LOG_FILE_NAME, 'r') as file:
        content = file.read()
    return render_template('admin.html', content=content)

@app.route('/remove_node', methods=['POST'])
def remove_node():
    node_id = request.form['rid']
    print(f'NodeID to remove: {node_id}')
    
    send_kill(node_id)
    generate_graph("./../init/config_files")
    with open(LOG_FILE_NAME, 'r') as file:
        content = file.read()
    return render_template('admin.html', content=content)


#----------------------PEER---------------------------------

@app.route("/peer/", methods=['GET', 'POST'])
def peer():
    if request.method == 'GET':
        return render_template('peer.html')
    
    id_peerA = request.form.get('idpa')
    id_peerB = request.form.get('idpb')
    band = request.form.get('band')
    
    print(f'PeerA_ID = {id_peerA}\nPeerB_ID = {id_peerB}\nRequired bandwidth = {band}')
    #return render_template('peer.html')
    
    #send data to Erlang node via TCP
    if open_conn(id_peerA, id_peerB, band):
        return render_template('peer.html', status='HAS BEEN SENT CORRECTLY')
    else:
        return render_template('peer.html', status='HAS NOT BEEN SENTED! ERROR!')

@app.route("/close_conn/", methods=['GET', 'POST'])
def close_conn():
    if request.method == 'GET':
        return render_template('peer.html')
    
    id_peerA = request.form.get('idpa')
    id_peerB = request.form.get('idpb')

    close_conn(id_peerA, id_peerB)
    return render_template('peer.html')

#----------------------LOG---------------------------------
@app.route("/log/")
def get_file():
    return send_file(LOG_FILE_NAME, as_attachment=True)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
