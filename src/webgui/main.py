from flask import Flask, render_template, request
import os
import json
import socket
import graphviz

app = Flask(__name__, template_folder="templates")


def send_request(id_peer, band):

    #Open the socket
    #TODO: Define a dynamic approach for determine the Address and the Port
    TCP_ADDR = "127.0.0.2"
    TCP_PORT = 100

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(TCP_ADDR, TCP_PORT)
    s.sendall(id_peer, band)
    data = s.recv(1024)
    s.close()
    
    if "ACK" in data:
        return True
    else:
        return False


def generate_graph(PATH):
    """
    Function that generates the graph of the newtork reading the json files
    """
    if not("graph" in os.listdir(".")):
        os.mkdir("./graph")
    
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


    g.render('./graph/graph.gv').replace('\\', '/')


@app.route("/", methods=['GET', 'POST'])
def admin():
    if request.method == 'GET':
        return render_template('admin.html')
    
    return render_template('admin.html')

@app.route('/add_node', methods=['POST'])
def add_node():
    node_id = request.form['id']
    edges = request.form['edges']
    #PASSA DATI
    #STAMPA GRAFICO
    return render_template('admin.html')

@app.route('/remove_node', methods=['POST'])
def remove_node():
    node_id = request.form['rid']
    #PASSA DATI
    #STAMPA GRAFICO
    return render_template('admin.html')

@app.route("/peer/", methods=['GET', 'POST'])
def peer():
    if request.method == 'GET':
        return render_template('peer.html')
    
    id_peerA = request.form.get('idpa')
    id_peerB = request.form.get('idpb')
    band = request.form.get('band')
    
    print(f'PeerA_ID = {id_peerA}\nPeerB_ID = {id_peerB}\nRequired bandwidth = {band}')
    #return render_template('index.html')

    #send data to Erlang node via TCP
    """
    if send_request(id_peerA, id_peerB, band):
        return render_template('peer_good.html')
    else:
        return render_template('peer_error.html')
    """
    return render_template('peer.html')

if __name__ == "__main__":
    generate_graph("./../init/config_files")
    #app.run(host="127.0.0.1", port=8080)