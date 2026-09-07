all       :; forge build --sizes
clean     :; forge clean
test      :; forge test -vvv
fuzz      :; forge test -vvv --fuzz-runs 10000
deploy    :; forge script script/Deploy.s.sol:DeployScript --rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --broadcast --verify -vvv
