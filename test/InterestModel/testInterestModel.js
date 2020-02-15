const Web3 = require('web3');
const BN = require('bn.js');

const USDTRateModelNewABI = require("./abi/testInterestModel.json");

const web3 = new Web3(new Web3.providers.HttpProvider("https://rinkeby.infura.io/v3/" + infura_key));

const mantissOne = (new BN(10)).pow(new BN(16))

const configList = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100];

const NewAddress = '0x0382274E6935c9655f715F1A577E84177Ea716E5';
const contract = new web3.eth.Contract(USDTRateModelNewABI, NewAddress);

async function main() {
    console.log('\n\n')
    console.log('Borrow APR')

    for (let i = 0, len = configList.length; i < len; i++) {
        let data = ((new BN(configList[i])).mul(mantissOne)).toString()
        let result = await contract.methods.getBorrowRate(data).call()
        console.log("result is: ", configList[i], result[1].toString() * 2102400 / 10 ** 18)

    }

    console.log('\n\n')
    console.log('Supply APR')

    for (let i = 0, len = configList.length; i < len; i++) {
        let data = ((new BN(configList[i])).mul(mantissOne)).toString()
        let result = await contract.methods.getSupplyRate(data).call()
        console.log("result is: ", configList[i], result[1].toString() * 2102400 / 10 ** 18)

    }
}


main()
