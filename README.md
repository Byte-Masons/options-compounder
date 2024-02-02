# OptionsToken Compounder

A token with options that grant the holder the ability to acquire the base token at a rate specified by an oracle. Resembling a call option, it differs in having a strike price consistently set at a specific discount to the market rate and it lacks an expiration date. The Compounder platform facilitates the utilization of flash loans to exercise the option, enabling the acquisition of the underlying token at a discounted rate via payment token.

## Installation

```
forge install 
```
## Tests

.env.example -> .env -> populate rpc providers

```
forge test
```
