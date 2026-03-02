# oc login en cada nodo (acm + 2 ocp)
# oc config get-contexts
# oc config rename-context default/api-cluster-*****-dynamic-redhatworkshops-io:6443/admin acm (luego de acm, hacer east y west)
# python3 -m venv venv
# source venv/bin/activate   
# python3 -m pip install -r requirements.txt  
# ansible-galaxy collection install -r ansible/collections/requirements.yml     
# ./install-multi-cluster.sh  