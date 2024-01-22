# OptionsToken Compounder

A token with options that grant the holder the ability to acquire the base token at a rate specified by an oracle. Resembling a call option, it differs in having a strike price consistently set at a specific discount to the market rate and it lacks an expiration date. The Compounder platform facilitates the utilization of flash loans to exercise the option, enabling the acquisition of the underlying token at a discounted rate via payment token.

## Installation

To install with [DappTools](https://github.com/dapphub/dapptools):

```
dapp install timeless-fi/options-token
```

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install timeless-fi/options-token
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
forge install
```

### Compilation

```
forge build
```

### Testing

```
forge test
```