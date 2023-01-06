You can send custom metrics to Middleware Backend Using the API given below

POST https://${accountUID}.middleware.io/v1/metrics

```
curl -X POST "https://${accountUID}.middleware.io/v1/metrics" \
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
              "string_value": ${YOUR-API-KEY}
            }
          },
          {
            "key": "type",
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
