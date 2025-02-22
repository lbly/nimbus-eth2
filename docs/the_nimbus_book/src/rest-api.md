# REST API

Nimbus exposes a high-performance implementation of the [Beacon Node API](https://ethereum.github.io/beacon-APIs/).

The API is a `REST` interface accessed via `HTTP`. The API should not, unless protected by additional security layers, be exposed to the public Internet as the API includes multiple endpoints which could open your node to denial-of-service (DoS) attacks.

The API can be used with any conforming consumer, including alternative validator client implementations, explorers and tooling.

## Configuration

By default, the REST interface is disabled. To enable it, start the beacon node with the `--rest` option, then access the API from http://localhost:5052/.

> **Warning:** If you are using a validator client with a Nimbus beacon node, and running a Nimbus version prior to `v1.5.5`,  then you will need to launch the node with the `--subscribe-all-subnets` option enabled.

By default, only connections from the same machine are entertained. The port and listening address can be further configured through the options `--rest-port` and `--rest-address`.

## Specification

The specification is documented [here](https://ethereum.github.io/beacon-APIs/).

See the Readme [here](https://github.com/ethereum/beacon-APIs).

## Quickly test your tooling against Nimbus

 The [Nimbus REST api](https://nimbus.guide/rest-api.html) is now available from:

* http://testing.mainnet.beacon-api.nimbus.team/
* http://unstable.mainnet.beacon-api.nimbus.team/
* http://unstable.prater.beacon-api.nimbus.team/

Note that right now these are very much unstable testing instances. They may be unresponsive at times - so **please do not rely on them for validation**. We may also disable them at any time.
