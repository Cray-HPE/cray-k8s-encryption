# cray-k8s-encryption

This is the helm chart used for kubernetes data encryption rewriting. Note this could technically be ran on any kubernetes cluster the presumption is this is ran on a cluster admined by kubeadm.

## Installation

```sh
helm upgrade --install cray-k8s-encryption ./charts/cray-k8s-encryption
```

## Control Plane Node Expectations

Control plane nodes have an `/etc/kubernetes/encryption` directory with a file or symlink to an encryption configuration file is present named `current.yaml`. If this is not true, the daemonset won't fail but at worst will cause a needless rewrite of data.

## Notable Values

For a normal user the only real configuration that may need tweaking, if ran on a non cray kubeadm cluster is:
- encryptionConfigDir: This directory is mounted by the daemonset to read the current encryption configuration. It expects a file, or symlink of *current.yaml*
- environment.interval: Interval in seconds between changes to the file. Default is 600, changing it down below 30 seconds is not recommended nor needed.
- environment.verbose: Boolean "true" or "false" for more output.

## Logic

The daemonset will periodically wake up and ensure that every control plane node has the same encryption configuration and update the node annotation to match.

These node annotations are used to determine if any objects in kubernetes need to be rewritten. For the moment only secrets are supported and rewritten.

To determine this a secret is created, `cray-k8s-encryption` by default in the `kube-system` namespace. It records the current expected encryption configuration state and last known write time of any data affected.

A quick peek at the annotations reveals the logic:

```text
$ kubectl get secret cray-k8s-encryption -o json -n kube-system | jq ".metadata.annotations"
{
  "changed": "2022-06-23 16:39:02+0000",
  "current": "identity",
  "generation": "2",
  "goal": "identity",
  "meta.helm.sh/release-name": "cray-k8s-encryption",
  "meta.helm.sh/release-namespace": "default"
}
```

On the first control plane only, if all current node annotations are equal, and the 0 index encryption name differs from the goal annotation on that secret, a rewrite is needed if and only if goal differs from current.

If for any reason rewriting fails, the first node will retry rewriting until it can succeed.

If it does succeed, the current encryption string is updated to match the goal and all further updates to any data will not happen. At that time the generation is incremented and the changed annotation is updated with the time in UTC of the last known rewrite.

## Forcing a change

If for whatever reason you want to force a rewrite of data, you may simply update the current annotation to any string that isn't in the goal annotation. At the next
wake up interval all data will be rewritten.

Example:

```text
$ kubectl annotate secret --namespace kube-system cray-k8s-encryption current=changeme --overwrite
$ kubectl get secret cray-k8s-encryption -o json -n kube-system | jq ".metadata.annotations"
{
  "changed": "2022-06-23 17:51:37+0000",
  "current": "identity",
  "generation": "3",
  "goal": "identity",
  "meta.helm.sh/release-name": "cray-k8s-encryption",
  "meta.helm.sh/release-namespace": "default"
}
```
