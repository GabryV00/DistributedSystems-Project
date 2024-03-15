from flask import Flask, render_template, request
import socket

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
    if "ACK" in data:
        return True
    else:
        return False

    s.close()

@app.route("/", methods=['GET', 'POST'])
def hello():
    if request.method == 'GET':
        return render_template('index.html')
    
    id_peer = request.form.get('idp')
    band = request.form.get('band')
    
    print(f'Peer_ID = {id_peer}\nRequired bandwidth = {band}')
    #return render_template('index.html')

    #send data to Erlang node via TCP
    if send_request(id_peer, band):
        return render_template('good.html')
    else:
        return render_template('error.html')

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)