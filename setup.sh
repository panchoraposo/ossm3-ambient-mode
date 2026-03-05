# oc login en cada nodo (acm2 + 2 ocp)
# oc config get-contexts
# oc config rename-context default/api-... acm2 (luego, hacer east2 y west2)
# python3 -m venv venv
# source venv/bin/activate   
# python3 -m pip install -r requirements.txt  
# ansible-galaxy collection install -r ansible/collections/requirements.yml     
# ./install-multi-cluster.sh  