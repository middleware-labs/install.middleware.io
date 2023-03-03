### Use our easy one-step install.

```
MW_API_KEY= TARGET= bash -c "$(curl -L https://install.middleware.io/scripts/apt-install.sh)"
```

**Note : You must not run more than one MW Agent per node. Running multiple Agents may result in unexpected behavior.**

Check Status of Middleware Agent using ...

```
sudo systemctl status mwservice
```


--------------------


## Supported Machines

| Independent Systems | |
|-|-|
|Ubuntu 18.04 | x86 + ARM
|Ubuntu 20.04 | x86 + ARM
|Ubuntu 22.04 | x86 + ARM

| Amazon Web Services | |
|-|-|
|Ubuntu 18.04 | x86 + ARM
|Ubuntu 20.04 | x86 + ARM
|Ubuntu 22.04 | x86 + ARM

For Ubuntu 16.04 and older, we suggest to stick with Docker Installation

Let us know, if you find more machines that works well with our agent.

Also let us know if you need support for any particular Architecture / OS version that is not listed above.

## Roadmap

1. We are planning to add support for RPM based machines.
