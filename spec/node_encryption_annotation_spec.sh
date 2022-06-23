#!/usr/bin/env sh
#-*-mode: Shell-script; coding: utf-8;-*-
#
# Document/describe how the encryption works for etcd on a k8s cluster.
#
# Not comprehensive? I've tried to do as many "demonstrate I understand this
# fully" proofs here but there is no guarantee that I have. But if its not here,
# I didn't validate/test it most likely or feel it peritenent.

Describe 'node-encryption-annotation.sh works as expected'
  Include charts/cray-k8s-encryption/files/node-encryption-annotation.sh

  # Note using function mocks for testing ref:
  # https://github.com/shellspec/shellspec#mocking
  #
  # Essentially we're defining a mini "world" where these specific functions
  # return what we specify to test logic outside of a runtime env like any other
  # language.
  Context 'happy path when run on a control-plane node'
    nodename() {
      printf "mock-hostname\n"
    }

    kubectl_get_controlplane_nodes() {
      printf "mock-hostname\nanother-hostname\n"
    }

    all_ready_controlplane_nodes() {
      printf "mock-hostname\nanother-hostname\n"
    }

    It 'nodename can be mocked'
      When call nodename
      The stdout should eq "mock-hostname"
    End

    It 'kubectl_get_controlplane_nodes can be mocked'
      When call kubectl_get_controlplane_nodes
      The line 1 of stdout should equal "mock-hostname"
      The line 2 of stdout should equal "another-hostname"
    End

    It 'all_ready_controlplane_nodes can be mocked'
      When call all_ready_controlplane_nodes
      The line 1 of stdout should equal "mock-hostname"
      The line 2 of stdout should equal "another-hostname"
    End

    It 'nodename_updateable returns 0 on a control-plane node'
      When call nodename_updateable
      The status should equal 0
    End
  End

  # (Un)happy path 1, we are being run on a control-plane node somehow
  Context 'unhappy path not run on a control-plane node'
    nodename() {
      printf "some-worker\n"
    }

    kubectl_get_controlplane_nodes() {
      printf "mock-hostname\nanother-hostname\n"
    }

    It 'nodename_updateable returns 1 on a non control-plane node'
      When call nodename_updateable
      The status should equal 1
    End
  End

  # (Un)happy path 2, all nodes aren't Ready
  Context 'unhappy path not all control-plane nodes ready'
    nodename() {
      printf "some-worker\n"
    }

    kubectl_get_controlplane_nodes() {
      printf "mock-hostname\nanother-hostname\n"
    }

    all_ready_controlplane_nodes() {
      printf "mock-hostname"
    }

    It 'all_ready_controlplane_nodes can be mocked'
      When call all_ready_controlplane_nodes
      The line 1 of stdout should equal "mock-hostname"
    End

    It 'all_controlplane_nodes_online() returns 1 when not all nodes online'
      When call all_controlplane_nodes_online
      The status should equal 1
    End

    It 'nodename_updateable returns 1 on a non control-plane node'
      When call nodename_updateable
      The status should equal 1
    End
  End

  # Encryption config file checks
  Context 'encryption configuration parsing'
    Context 'identity configuration'
      read_ec_file() {
        %text
        #|---
        #|apiVersion: apiserver.config.k8s.io/v1
        #|kind: EncryptionConfiguration
        #|resources:
        #|  - resources:
        #|      - secrets
        #|    providers:
        #|      - identity: {}
      }
      It 'ec_providers returns identity'
        When call ec_providers
        The stdout should equal "identity"
      End

      It 'valid_providers returns 0'
        When call valid_providers
        The status should equal 0
        End

      It 'encryption_config_annotation'
        When call encryption_config_annotation
        The stdout should equal "identity"
      End
    End

    Context 'unrecognized providers setup somehow'
      read_ec_file() {
        %text
        #|---
        #|apiVersion: apiserver.config.k8s.io/v1
        #|kind: EncryptionConfiguration
        #|resources:
        #|  - resources:
        #|      - secrets
        #|    providers:
        #|      - identity: {}
        #|      - aesgcm:
        #|          keys:
        #|            - name: key1
        #|              secret: c2VjcmV0IGlzIHNlY3VyZQ==
        #|            - name: key2
        #|              secret: dGhpcyBpcyBwYXNzd29yZA==
        #|      - aescbc:
        #|          keys:
        #|            - name: key3
        #|              secret: c2VjcmV0IGlzIHNlY3VyZQ==
        #|            - name: key4
        #|              secret: dGhpcyBpcyBwYXNzd29yZA==
        #|      - secretbox:
        #|          keys:
        #|            - name: key5
        #|              secret: YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=
      }
      It 'ec_providers returns all provider keys'
        When call ec_providers
        The line 1 of stdout should equal "identity"
        The line 2 of stdout should equal "aesgcm"
        The line 3 of stdout should equal "aescbc"
        The line 4 of stdout should equal "secretbox"
      End

      It 'valid_providers returns 1'
        When call valid_providers
        The status should equal 1
      End

      # Since we have this fake encryption config file stubbed already validate
      # a few more things output what we want here too
      It 'encryption_config_annotation'
        When call encryption_config_annotation
        The stdout should equal "identity,aesgcm:key1,aesgcm:key2,aescbc:key3,aescbc:key4,secretbox:key5"
      End
    End

    Context 'misc function tests'
      It 'should have annotation prefix we expect'
        When call annotation_prefix
        The output should equal "cray-k8s-encryption"
      End

      It 'encryption_config_annotation always returns identity by default'
        When call encryption_config_annotation
        The stdout should equal "identity"
      End
    End

    # Note: After here is all logic used for determining when the first/primary
    # control-plane node determines when it is ok to rewrite secrets with a new key.
    Context 'control-plane node happy-path, all annotations return the same value and agree'
      get_controlplane_encryption_annotations() {
        printf "a\na\na\n"
      }

      all_controlplane_nodes_online() {
        return 0
      }

      It 'can_update says we are ok to update in this case'
        When call can_update
        The status should equal 0
      End
    End

    # Failure case: If we're somehow run on a node with no annotations, we want
    # to make sure we do not run, lets just say for now all nodes are online
    # too, though thats tested in another failure context
    Context 'control-plane update failure path, no node annotations/run on a node without any bss data or setup yet... somehow'
      get_controlplane_encryption_annotations() {
        printf "\n\n\n"
      }

      all_controlplane_nodes_online() {
        return 0
      }

      It 'can_update says no'
        When call can_update
        The status should equal 1
      End
    End

    Context 'control-plane annotations do not all match'
      get_controlplane_encryption_annotations() {
        printf "a\nb\n"
      }

      all_controlplane_nodes_online() {
        return 0
      }

      It 'can_update says no'
        When call can_update
        The status should equal 1
      End
    End

    # Secret annotation cases that control secret update logic

    # Use case: fresh install and our new key isn't what we want, aka whatever
    # it was isn't what we know to be written, so we'll allow rewrites to be
    # whatever is currently configured.
    Context 'secret annotation new install'
      secret_current() {
        printf "unknown"
      }

      secret_goal() {
        printf "unknown"
      }

      It 'can_update_secret says yes'
        When call can_update_secret
        The status should equal 0
      End
    End

    # Use case:
    # - moving from identity encryption (aka none)
    # - to some aescbc:name or another, basically we turn on encryption after the fact
    Context 'secret annotation identity->something'
      secret_current() {
        printf "identity"
      }

      secret_goal() {
        printf "aescbc:foobar"
      }

      It 'can_update_secret says yes'
        When call can_update_secret
        The status should equal 0
      End
    End

    # Use case:
    # - moving from some aescbc:name
    # - to another aescbc:name
    Context 'secret annotation something->somethingelse'
      secret_current() {
        printf "aescbc:name"
      }

      secret_goal() {
        printf "aescbc:name2"
      }

      It 'can_update_secret says yes'
        When call can_update_secret
        The status should equal 0
      End
    End

    # Use case:
    # - moving from some aescbc:name
    # - to identity (turning off encryption)
    Context 'secret annotation encryption->identity'
      secret_current() {
        printf "aescbc:name"
      }

      secret_goal() {
        printf "aescbc:name2"
      }

      It 'can_update_secret says yes'
        When call can_update_secret
        The status should equal 0
      End
    End

    # Non happy-path, current = goal, we should not rewrite secrets
    Context 'secret annotation ensure rewrites do not happen'
      secret_current() {
        printf "aescbc:name"
      }

      secret_goal() {
        printf "aescbc:name"
      }

      It 'can_update_secret says no'
        When call can_update_secret
        The status should equal 1
      End
    End
  End
End
