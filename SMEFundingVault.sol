// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SMEFundingVault is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdcToken;
    
    uint256 public immutable fundingGoal;
    uint256 public immutable fundingDeadline;
    uint256 public totalRaised;
    
    bool public isFundingSuccessful;
    bool public capitalWithdrawn;

    // Variaveis para controle de distribuicao de rendimentos pro-rata
    uint256 private constant MAGNITUDE = 2**128;
    uint256 private magnifiedYieldPerShare;
    mapping(address => uint256) private magnifiedYieldCorrections;
    mapping(address => uint256) private withdrawnYields;

    // Eventos
    event Deposit(address indexed investor, uint256 amount);
    event GoalReached(uint256 totalAmount);
    event CapitalWithdrawn(address indexed owner, uint256 amount);
    event RefundIssued(address indexed investor, uint256 amount);
    event YieldPaid(uint256 amount);
    event YieldClaimed(address indexed investor, uint256 amount);

    constructor(
        address _usdc,
        uint256 _goal,
        uint256 _durationDays
    ) ERC20("Hotel Logistics Bond", "HTL-BOND") Ownable(msg.sender) {
        usdcToken = IERC20(_usdc);
        fundingGoal = _goal;
        fundingDeadline = block.timestamp + (_durationDays * 1 days);
    }

    // ==========================================
    // FUNCAO A: CAPTACAO (Investidor deposita USDC)
    // ==========================================
    function invest(uint256 amount) external nonReentrant {
        require(block.timestamp <= fundingDeadline, "Prazo de captacao encerrado");
        require(!isFundingSuccessful, "Meta ja atingida");
        require(amount > 0, "O valor deve ser maior que zero");
        require(totalRaised + amount <= fundingGoal, "Excede a meta de captacao");

        totalRaised += amount;
        if (totalRaised == fundingGoal) {
            isFundingSuccessful = true;
            emit GoalReached(totalRaised);
        }

        usdcToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Emite o token de recibo (1 HTL-BOND para cada 1 USDC)
        _mint(msg.sender, amount); 
        
        // Ajusta a correcao de dividendos para o novo saldo
        magnifiedYieldCorrections[msg.sender] -= (int256(magnifiedYieldPerShare * amount));

        emit Deposit(msg.sender, amount);
    }

    // ==========================================
    // FUNCAO B: SAQUE DA EMPRESA (Dono retira USDC)
    // ==========================================
    function withdrawCapital() external onlyOwner {
        require(isFundingSuccessful, "A meta nao foi atingida");
        require(!capitalWithdrawn, "Capital ja foi sacado");

        capitalWithdrawn = true;
        
        // O dono saca apenas o valor principal arrecadado, mantendo eventuais rendimentos no contrato
        usdcToken.safeTransfer(owner(), totalRaised);

        emit CapitalWithdrawn(owner(), totalRaised);
    }

    // ==========================================
    // FUNCAO C: REEMBOLSO (Se a captacao falhar)
    // ==========================================
    function refund() external nonReentrant {
        require(block.timestamp > fundingDeadline, "Prazo de captacao ainda ativo");
        require(!isFundingSuccessful, "A captacao foi um sucesso");
        
        uint256 balance = balanceOf(msg.sender);
        require(balance > 0, "Nenhum token para reembolso");

        _burn(msg.sender, balance);
        usdcToken.safeTransfer(msg.sender, balance);

        emit RefundIssued(msg.sender, balance);
    }

    // ==========================================
    // FUNCAO D1: PAGAR RENDIMENTO (Empresa deposita lucro)
    // ==========================================
    function payYield(uint256 amount) external onlyOwner {
        require(totalSupply() > 0, "Nenhum token emitido");
        require(amount > 0, "Valor invalido");

        usdcToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Distribui o valor proporcionalmente entre todas as cotas existentes
        magnifiedYieldPerShare += (amount * MAGNITUDE) / totalSupply();

        emit YieldPaid(amount);
    }

    // ==========================================
    // FUNCAO D2: SACAR RENDIMENTO (Investidor resgata)
    // ==========================================
    function claimYield() external nonReentrant {
        uint256 withdrawableYield = withdrawableYieldOf(msg.sender);
        require(withdrawableYield > 0, "Nenhum rendimento disponivel");

        withdrawnYields[msg.sender] += withdrawableYield;
        usdcToken.safeTransfer(msg.sender, withdrawableYield);

        emit YieldClaimed(msg.sender, withdrawableYield);
    }

    // Calcula o rendimento disponivel para um endereco
    function withdrawableYieldOf(address account) public view returns (uint256) {
        return accumulativeYieldOf(account) - withdrawnYields[account];
    }

    // Calcula o rendimento total acumulado historico
    function accumulativeYieldOf(address account) public view returns (uint256) {
        int256 a = int256(magnifiedYieldPerShare * balanceOf(account));
        int256 b = magnifiedYieldCorrections[account];
        return uint256(a + b) / MAGNITUDE;
    }

    // Sobrescrita do _transfer para manter a contabilidade dos dividendos correta se o token for negociado
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        
        int256 _magCorrection = int256(magnifiedYieldPerShare * value);
        if (from != address(0)) {
            magnifiedYieldCorrections[from] += _magCorrection;
        }
        if (to != address(0)) {
            magnifiedYieldCorrections[to] -= _magCorrection;
        }
    }
}
