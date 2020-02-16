const Web3 = require('web3');
const BN = require('bn.js');

const USDTRateModelNewABI = require("./abi/testInterestModel.json");

// Add your own infura key at here!
const web3 = new Web3(new Web3.providers.HttpProvider("https://rinkeby.infura.io/v3/" + INFURA_KEY));

const mantissOne = (new BN(10)).pow(new BN(12))

// If you want to test for the specific number, add to following array list,
// !!!!!!!!!!
// !! Note !!: the number has four decimal places, so if we want to test UR=5.67%, we should input 56700.
// !!!!!!!!!!
// default is 0% ～ 100%, that is there are 100 sets of data.
// const configList = [56700, 100000];
let configList = [];

const NewAddress = '0x1993Ef555636C0591b3fCA51a5301dA91a35ee87';
const contract = new web3.eth.Contract(USDTRateModelNewABI, NewAddress);

async function main() {
    console.log('Borrow APR')

    let len = configList.length === 0 ? 102 : configList.length
    if (configList.length === 0) {
        for (let i = 0; i < 101; i++) {
            configList.push(i*10**4)
        }
    }

    for (let i = 0; i < len; i++) {
        let data = ((new BN(configList[i])).mul(mantissOne)).toString()
        let result = await contract.methods.getBorrowRate(data).call()
        console.log("result is: ", configList[i]/10**4, "%", result[1].toString() * 2102400 / 10 ** 18)
    }

    console.log('\n\n')
    console.log('Supply APR')

    for (let i = 0; i < len; i++) {
        let data = ((new BN(configList[i])).mul(mantissOne)).toString()
        let result = await contract.methods.getSupplyRate(data).call()
        console.log("result is: ", configList[i]/10**4, "%", result[1].toString() * 2102400 / 10 ** 18)
    }
}


main()
