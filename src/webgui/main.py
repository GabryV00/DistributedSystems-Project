from flask import Flask, render_template, request
import os
import json
import socket
import graphviz

app = Flask(__name__, template_folder="templates")

ADMIN_PORT = 9000
PEER_PORT = 9001
TCP_ADDR = "127.0.0.1"

def send_request(id_peerA, id_peerB, band):

    #Open the socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((TCP_ADDR, PEER_PORT))
    dictionary = {
            "type": 'req_conn',
            "idA" : id_peerA,
            "idB" : id_peerB,
            "band" : band
        }
    s.sendall(str(dictionary).encode())
    data = s.recv(1024)
    s.close()
    
    if "ACK" in data:
        return True
    else:
        return False

def send_new(id_peer, edges):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((TCP_ADDR, ADMIN_PORT))
    dictionary = {
            "type": 'new_peer',
            "id" : id_peer,
            "edges" : edges
        }
    s.sendall(str(dictionary).encode())
    #data = s.recv(1024)
    s.close()

def send_kill(id_peer):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((TCP_ADDR, ADMIN_PORT))
    dictionary = {
            "type": 'rem_peer',
            "id" : id_peer
        }
    s.sendall(str(dictionary).encode())
    #data = s.recv(1024)
    s.close()

def generate_graph(PATH, mst=False):
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
        for n in edges:
            g.edge(f'{id_a}', f'{n[0]}', label=f'{n[1]}', color='blue')

    if mst:
        g.render('./static/mst.gv').replace('\\', '/')
    else:
        g.render('./static/graph.gv').replace('\\', '/')


@app.route("/", methods=['GET', 'POST'])
def admin():
    if request.method == 'GET':
        generate_graph("./../init/config_files")
        return render_template('admin.html')
    generate_graph("./../init/config_files")
    return render_template('admin.html')

@app.route('/add_node', methods=['POST'])
def add_node():
    node_id = request.form['id']
    edges = request.form['edges']
    print(f'NodeID: {node_id}\nEdges:{edges}')
    
    send_new(node_id, edges)
    generate_graph("./../init/config_files")
    
    return render_template('admin.html')

@app.route('/remove_node', methods=['POST'])
def remove_node():
    node_id = request.form['rid']
    print(f'NodeID to remove: {node_id}')
    
    send_kill(node_id)
    generate_graph("./../init/config_files")
    
    return render_template('admin.html')

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
    
    if send_request(id_peerA, id_peerB, band):
        return render_template('peer_good.html')
    else:
        return render_template('peer_error.html')

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)