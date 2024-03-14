from flask import Flask, render_template, request

app = Flask(__name__, template_folder="templates")

@app.route("/", methods=['GET', 'POST'])
def hello():
    if request.method == 'GET':
        return render_template('index.html')
    
    id_peer = request.form.get('idp')
    band = request.form.get('band')

    print(f'Peer_ID = {id_peer}\nRequired bandwidth = {band}')

    return render_template('index.html')

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)