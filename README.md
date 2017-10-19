# etcd

1. edit inventory file hosts
1. run ansible commands

  ``` shell
  ansible-playbook -i hosts site.yml
  ```

1. shutdown instance and create image
1. update imageid in cluster.json.mustache
1. upload configuration