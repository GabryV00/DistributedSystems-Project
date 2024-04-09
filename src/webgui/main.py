import os
import time
import json
import socket
import graphviz
from utils import string_to_list
from flask import Flask, render_template, send_file, request

app = Flask(__name__, template_folder="templates")

ADMIN_PORT = 9000
PEER_PORT = 9000
TCP_ADDR = "127.0.0.1"

LOG_FILE_NAME = '../../p2p_app/logs/log.txt'

OPEN_CONN = []

def parse_list_to_string(input_list):
    result = ""
    for sublist in input_list:
        result += f"NodeA: {sublist[0]}, NodeB: {sublist[1]}, Band: {sublist[2]}\n"
    return result

def interpret_response(data):
    """
    Function that takes bytes in inputs and return the interpretation of the json
    """
    res = json.loads(data.decode())
    ris = res['outcome']
    msg = res['message']

    return ris, msg

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

    return interpret_response(data)

def close_con(id_peerA, id_peerB):
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
    data = s.recv(1024)
    s.close()
    return interpret_response(data)

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
    return interpret_response(data)

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
    return interpret_response(data)

def generate_graph(PATH):
    """
    Function that generates the graph of the newtork reading the json files
    """

    time.sleep(1) # wait for MST to be computed

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
            node_data = json.load(fl)
            edges = node_data["edges"]
            edges_mst = node_data["mst"]
        for n in edges:
            g.edge(f'{id_a}', f'{n[0]}', label=f'{n[1]}', color='blue')
        for n in edges_mst:
           g.edge(f'{id_a}', f'{n[0]}', label=f'{n[1]}', color='green', penwidth='1.5')

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
    """
    Function that manages the creation of a new peer
    """
    node_id = request.form['id']
    edges = request.form['edges']
    # print(f'NodeID: {node_id}\nEdges:{edges}')
    
    ris, msg = send_new(node_id, edges)
    generate_graph("./../init/config_files")
    with open(LOG_FILE_NAME, 'r') as file:
        content = file.read()
    return render_template('admin.html', content=content, status=ris, message=msg)

@app.route('/remove_node', methods=['POST'])
def remove_node():
    """
    Function that allows to remove a peer
    """
    node_id = request.form['rid']
    # print(f'NodeID to remove: {node_id}')
    
    ris, msg = send_kill(node_id)
    if [node_id, _, _] in OPEN_CONN:
        OPEN_CONN.remove([node_id, _, _])
    if [_, node_id, _] in OPEN_CONN:
        OPEN_CONN.remove([_, node_id, _])

    generate_graph("./../init/config_files")
    with open(LOG_FILE_NAME, 'r') as file:
        content = file.read()
    return render_template('admin.html', content=content, status=ris, message=msg)


#----------------------PEER---------------------------------

@app.route("/peer", methods=['GET', 'POST'])
def peer():
    if request.method == 'GET':
        return render_template('peer.html',  oc=OPEN_CONN)
    
    id_peerA = request.form.get('idpa')
    id_peerB = request.form.get('idpb')
    band = request.form.get('band')
    
    # print(f'PeerA_ID = {id_peerA}\nPeerB_ID = {id_peerB}\nRequired bandwidth = {band}')
    #return render_template('peer.html')
    
    #send data to Erlang node via TCP

    ris, msg = open_conn(id_peerA, id_peerB, band)

    if 'ok' in ris:
        OPEN_CONN.append([id_peerA, id_peerB, band])
    return render_template('peer.html', status=ris, message=msg, oc=parse_list_to_string(OPEN_CONN))

@app.route("/close_conn", methods=['GET', 'POST'])
def close_conn():
    if request.method == 'GET':
        return render_template('peer.html',  oc=OPEN_CONN)
    
    id_peerA = request.form.get('idpa')
    id_peerB = request.form.get('idpb')

    ris, msg = close_con(id_peerA, id_peerB)
    if [id_peerA, id_peerB, _] in OPEN_CONN:
        OPEN_CONN.remove([id_peerA, id_peerb, _])
    if [id_peerB, id_peerA, _] in OPEN_CONN:
        OPEN_CONN.remove([id_peerB, id_peerA, _])
    return render_template('peer.html', status=ris, message=msg,  oc=parse_list_to_string(OPEN_CONN))

#----------------------LOG---------------------------------
@app.route("/log/")
def get_file():
    return send_file(LOG_FILE_NAME, as_attachment=True)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
