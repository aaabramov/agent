local default = import 'default/main.libsonnet';
local etcd = import 'etcd/main.libsonnet';
local agent_cluster = import 'grafana-agent/scraping-svc/main.libsonnet';
local k = import 'ksonnet-util/kausal.libsonnet';

local loki_config = import 'default/loki_config.libsonnet';
local grafana_agent = import 'grafana-agent/v1/main.libsonnet';

local ingress = k.networking.v1beta1.ingress;
local path = k.networking.v1beta1.httpIngressPath;
local rule = k.networking.v1beta1.ingressRule;
local service = k.core.v1.service;

local images = {
  agent: 'grafana/agent:latest',
  agentctl: 'grafana/agentctl:latest',
};

{
  default: default.new(namespace='default') {
    grafana+: {
      ingress+:
        ingress.new('grafana-ingress') +
        ingress.mixin.spec.withRules([
          rule.withHost('grafana.k3d.localhost') +
          rule.http.withPaths([
            path.withPath('/')
            + path.backend.withServiceName('grafana')
            + path.backend.withServicePort(80),
          ]),
        ]),
    },
  },

  agent:
    local cluster_label = 'k3d-agent/daemonset';

    grafana_agent.new('grafana-agent', 'default') +
    grafana_agent.withImages(images) +
    grafana_agent.withPrometheusConfig({
      wal_directory: '/var/lib/agent/data',
      global: {
        scrape_interval: '15s',
        external_labels: {
          cluster: cluster_label,
        },
      },
    }) +
    grafana_agent.withPrometheusInstances(grafana_agent.scrapeInstanceKubernetes {
      // We want our cluster and label to remain static for this deployment, so
      // if they are overwritten by a metric we will change them to the values
      // set by external_labels.
      scrape_configs: std.map(function(config) config {
        relabel_configs+: [{
          target_label: 'cluster',
          replacement: cluster_label,
        }],
      }, super.scrape_configs),
    }) +
    grafana_agent.withRemoteWrite([{
      url: 'http://cortex.default.svc.cluster.local/api/prom/push',
    }]) +
    grafana_agent.withLokiConfig(loki_config) +
    grafana_agent.withLokiClients(grafana_agent.newLokiClient({
      scheme: 'http',
      hostname: 'loki.default.svc.cluster.local',
      external_labels: { cluster: cluster_label },
    })),

  // Need to run ETCD for agent_cluster
  etcd: etcd.new('default'),

  agent_cluster:
    agent_cluster.new('default', 'kube-system') +
    agent_cluster.withImagesMixin(images) +
    agent_cluster.withConfigMixin({
      local kvstore = {
        store: 'etcd',
        etcd: {
          endpoints: ['etcd.default.svc.cluster.local:2379'],
        },
      },

      agent_remote_write: [{
        url: 'http://cortex.default.svc.cluster.local/api/prom/push',
      }],

      agent_ring_kvstore: kvstore { prefix: 'agent/ring/' },
      agent_config_kvstore: kvstore { prefix: 'agent/configs/' },

      local cluster_label = 'k3d-agent/cluster',
      agent_config+: {
        prometheus+: {
          global+: {
            external_labels+: {
              cluster: cluster_label,
            },
          },
        },
      },

      kubernetes_scrape_configs:
        (grafana_agent.scrapeInstanceKubernetes {
           // We want our cluster and label to remain static for this deployment, so
           // if they are overwritten by a metric we will change them to the values
           // set by external_labels.
           scrape_configs: std.map(function(config) config {
             relabel_configs+: [{
               target_label: 'cluster',
               replacement: cluster_label,
             }],
           }, super.scrape_configs),
         }).scrape_configs,
    }),
}
