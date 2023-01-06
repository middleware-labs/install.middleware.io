# Custom Metrics API

## Post your custom data
You can send custom metrics to Middleware Backend Using the API given below

`
POST https://{ACCOUNT-UID}.middleware.io/v1/metrics
`

-------------------------

```
curl -X POST "https://{MW-CUSTOM-METRICS-URL}/v1/metrics" \
-H "Accept: application/json" \
-H "Content-Type: application/json" \
-d @- << EOF
{
  "resource_metrics": [
    {
      "resource": {
        "attributes": [
          {
            "key": "mw.account_key",
            "value": {
              "string_value": {ACCOUNT-API-KEY}
            }
          },
          {
            "key": "mw.resource_type",
            "value": {
              "string_value": "custom"
            }
          }
        ]
      },
      "scope_metrics": [
        {
          "metrics": [
            {
              "name": "fluxcapacitor",
              "description": "Flux Capacitor Output",
              "unit": "watts",
              "gauge": {
                "data_points": [
                  {
                    "attributes": [
                      {
                        "key": "licenseplate",
                        "value": {
                          "string_value": "outatime"
                        }
                      }
                    ],
                    "start_time_unix_nano": 1668464803000000000,
                    "time_unix_nano": 1668464803000000000,
                    "asInt": 12345678
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
EOF
```

Note:
We accept data in OTLP/HTTP format
https://opentelemetry.io/docs/reference/specification/protocol/otlp/#otlphttp
as you can see in the sample above.


## Add data to Existing Middleware Resource Types
If you want to add your custom data to `Existing Middleware Resource Types`, you will have to add resource_attributes according to the list given below

Ex. If you want to add a metric for a "host" - you will need to add "host.id" resource attribute in your request body. Refer the table given below for the full list of supported types. 

| Type | Resource Attributes Required | Data will be stored to this Dataset |
|------ |----------| ----- |
| host | host.id | Host Metrics |
| k8s.node | k8s.node.uid | K8s Node Metrics | 
| k8s.pod | k8s.pod.uid | K8s POD metrics |
| k8s.deployment | k8s.deployment.uid | K8s Deployment Metrics |
| k8s.daemonset | k8s.deployment.uid | ~ |
| k8s.replicaset | k8s.deployment.uid | ~ |
| k8s.statefulset | k8s.deployment.uid | ~ |
| k8s.namespace | k8s.namespace.uid | ~ |
| service | service.name | ~ |
| os | os.type | ~ |



## Add purely custom data
If you want to add data that does not fall under the existing resource types, you have to pass resource_attributes as given below

```
mw.resource_type: custom
```

Data added using this resource attributes will be available under 
`Custom Metrics Dataset`


