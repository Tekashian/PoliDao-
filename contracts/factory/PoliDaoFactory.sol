// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
// Use minimal interfaces to avoid pulling full contract bytecode into the factory
interface IStorageInit {
    function initialize(address _commissionWalletArg, address _feeTokenArg, address _initialTokenArg, address initialOwner) external;
    function authorizeContract(address contractAddr) external;
    function setAuthorizedRouter(address router) external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

interface ICoreInit {
    function initialize(address _storageContract, address initialOwner) external;
    function setExtensionsContract(address _extensionsContract) external;
    function setRouterContract(address _routerContract) external;
    function transferOwnership(address newOwner) external;
    function setModules(address governance, address media, address updates, address refunds, address security, address web3, address analytics) external;
    function owner() external view returns (address);
}

interface IExtensionsInit {
    function initialize(address _storageContract, address _coreContract) external;
}

interface IRouterInit {
    function initialize(address _coreContract, address initialOwner) external;
}
import "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title PoliDaoFactory
 * @notice Factory contract for deploying complete PoliDAO systems
 * @dev Deploys and configures all contracts in the unified architecture
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 * @custom:security-contact security@polidao.org
 */
contract PoliDaoFactory is Ownable {
    // Initialize Ownable with deployer as owner
    constructor() Ownable(msg.sender) {}
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when a complete PoliDAO system is deployed
    event PoliDaoDeployed(
        address indexed deployer,
        address indexed storageContract,
        address indexed coreContract,
        address extensionsContract,
        address routerContract,
        string systemName
    );
    
    /// @notice Emitted when modules are set for a deployed system
    event ModulesConfigured(
        address indexed storageContract,
        address analytics,
        address governance,
        address media,
        address refunds,
        address security,
        address updates,
        address web3
    );
    
    // ========== DEPLOYMENT TRACKING ==========
    
    /// @notice Counter for deployed systems
    uint256 public deployedSystemsCount;
    
    /// @notice Mapping of deployment ID to system info
    mapping(uint256 => DeployedSystem) public deployedSystems;
    
    /// @notice Mapping of deployer to their deployed systems
    mapping(address => uint256[]) public deployerSystems;

    // Optional implementation addresses for clones pattern
    address public storageImplementation;
    address public coreImplementation;
    address public extensionsImplementation;
    address public routerImplementation;
    
    // ========== STRUCTS ==========
    
    /// @notice Information about a deployed PoliDAO system
    struct DeployedSystem {
        address deployer;
        address storageContract;
        address coreContract;
        address extensionsContract;
        address routerContract;
        uint256 deploymentTime;
        string systemName;
        bool isConfigured;
    }
    
    /// @notice Module addresses for configuration
    struct ModuleAddresses {
        address analytics;
        address governance;
        address media;
        address refunds;
        address security;
        address updates;
        address web3;
    }
    
    // ========== MAIN DEPLOYMENT FUNCTION ==========
    
    /**
     * @notice Deploys a complete PoliDAO system
     * @param commissionWallet Address where commissions will be sent
     * @param feeToken Address of token used for extension fees
     * @param initialToken Address of first whitelisted token
     * @param systemName Name identifier for this deployment
     * @return deploymentId Unique identifier for this deployment
     * @return storageContract Address of deployed storage contract
     * @return coreContract Address of deployed core contract
     * @return extensionsContract Address of deployed extensions contract
     * @return routerContract Address of deployed router contract
     */
    function deployFullPoliDao(
        address commissionWallet,
        address feeToken,
        address initialToken,
        string calldata systemName
    ) public returns (
        uint256 deploymentId,
        address storageContract,
        address coreContract,
        address extensionsContract,
        address routerContract
    ) {
        require(commissionWallet != address(0), "PoliDaoFactory: Invalid commission wallet");
        require(feeToken != address(0), "PoliDaoFactory: Invalid fee token");
        require(initialToken != address(0), "PoliDaoFactory: Invalid initial token");
        require(bytes(systemName).length > 0, "PoliDaoFactory: System name required");
        
        // Increment deployment counter
        deployedSystemsCount++;
        deploymentId = deployedSystemsCount;
        
        // ========== 1. DEPLOY STORAGE CONTRACT ==========
    require(storageImplementation != address(0), "PoliDaoFactory: storage implementation not set");
    // use clones
    storageContract = Clones.clone(storageImplementation);
    IStorageInit(storageContract).initialize(commissionWallet, feeToken, initialToken, msg.sender);
        
        // ========== 2. DEPLOY CORE CONTRACT ==========
    require(coreImplementation != address(0), "PoliDaoFactory: core implementation not set");
    coreContract = Clones.clone(coreImplementation);
    ICoreInit(coreContract).initialize(storageContract, msg.sender);
        
        // ========== 3. DEPLOY EXTENSIONS CONTRACT ==========
    require(extensionsImplementation != address(0), "PoliDaoFactory: extensions implementation not set");
    extensionsContract = Clones.clone(extensionsImplementation);
    IExtensionsInit(extensionsContract).initialize(storageContract, coreContract);
        
        // ========== 4. DEPLOY ROUTER CONTRACT ==========
    require(routerImplementation != address(0), "PoliDaoFactory: router implementation not set");
    routerContract = Clones.clone(routerImplementation);
    IRouterInit(routerContract).initialize(coreContract, msg.sender);
        
        // ========== 5. CONFIGURE CONNECTIONS ==========
        
    // Authorize core and extensions in storage
    IStorageInit(storageContract).authorizeContract(coreContract);
    IStorageInit(storageContract).authorizeContract(extensionsContract);

    // Set extensions contract in core
    ICoreInit(coreContract).setExtensionsContract(extensionsContract);

    // Set router contract in core
    ICoreInit(coreContract).setRouterContract(routerContract);

    // Set authorized router in storage
    IStorageInit(storageContract).setAuthorizedRouter(routerContract);

    // ========== 6. TRANSFER OWNERSHIP TO DEPLOYER ==========

    IStorageInit(storageContract).transferOwnership(msg.sender);
    ICoreInit(coreContract).transferOwnership(msg.sender);
        
        // ========== 7. RECORD DEPLOYMENT ==========
        
        deployedSystems[deploymentId] = DeployedSystem({
            deployer: msg.sender,
            storageContract: storageContract,
            coreContract: coreContract,
            extensionsContract: extensionsContract,
            routerContract: routerContract,
            deploymentTime: block.timestamp,
            systemName: systemName,
            isConfigured: false
        });
        
        deployerSystems[msg.sender].push(deploymentId);
        
        // ========== 8. EMIT EVENT ==========
        
        emit PoliDaoDeployed(
            msg.sender,
            storageContract,
            coreContract,
            extensionsContract,
            routerContract,
            systemName
        );
        
        return (
            deploymentId,
            storageContract,
            coreContract,
            extensionsContract,
            routerContract
        );
    }

    // ========== ADMIN: set implementation addresses for clones ==========
    function setImplementations(address _storageImpl, address _coreImpl, address _extensionsImpl, address _routerImpl) external onlyOwner {
        storageImplementation = _storageImpl;
        coreImplementation = _coreImpl;
        extensionsImplementation = _extensionsImpl;
        routerImplementation = _routerImpl;
    }
    
    // ========== MODULE CONFIGURATION ==========
    
    /**
     * @notice Configures modules for a deployed system
     * @param deploymentId The deployment ID
     * @param modules Struct containing all module addresses
     */
    function configureModules(
        uint256 deploymentId,
        ModuleAddresses calldata modules
    ) public {
        require(deploymentId <= deployedSystemsCount && deploymentId > 0, "PoliDaoFactory: Invalid deployment ID");
        
        DeployedSystem storage system = deployedSystems[deploymentId];
        require(system.deployer == msg.sender, "PoliDaoFactory: Only deployer can configure");
        require(!system.isConfigured, "PoliDaoFactory: Already configured");
        
        // Validate module addresses
        require(modules.analytics != address(0), "PoliDaoFactory: Invalid analytics module");
        require(modules.governance != address(0), "PoliDaoFactory: Invalid governance module");
        require(modules.media != address(0), "PoliDaoFactory: Invalid media module");
        require(modules.refunds != address(0), "PoliDaoFactory: Invalid refunds module");
        require(modules.security != address(0), "PoliDaoFactory: Invalid security module");
        require(modules.updates != address(0), "PoliDaoFactory: Invalid updates module");
        require(modules.web3 != address(0), "PoliDaoFactory: Invalid web3 module");
        
        // Configure modules in core contract
        ICoreInit(system.coreContract).setModules(
            modules.governance,
            modules.media,
            modules.updates,
            modules.refunds,
            modules.security,
            modules.web3,
            modules.analytics
        );
        
        // Authorize modules in storage contract
    IStorageInit(system.storageContract).authorizeContract(modules.analytics);
    IStorageInit(system.storageContract).authorizeContract(modules.governance);
    IStorageInit(system.storageContract).authorizeContract(modules.media);
    IStorageInit(system.storageContract).authorizeContract(modules.refunds);
    IStorageInit(system.storageContract).authorizeContract(modules.security);
    IStorageInit(system.storageContract).authorizeContract(modules.updates);
    IStorageInit(system.storageContract).authorizeContract(modules.web3);
        
        // Mark as configured
        system.isConfigured = true;
        
        // Emit event
        emit ModulesConfigured(
            system.storageContract,
            modules.analytics,
            modules.governance,
            modules.media,
            modules.refunds,
            modules.security,
            modules.updates,
            modules.web3
        );
    }
    
    // ========== DEPLOYMENT WITH MODULES ==========
    
    /**
     * @notice Deploys a complete PoliDAO system with modules in one transaction
     * @param commissionWallet Address where commissions will be sent
     * @param feeToken Address of token used for extension fees
     * @param initialToken Address of first whitelisted token
     * @param systemName Name identifier for this deployment
     * @param modules Struct containing all module addresses
     * @return deploymentId Unique identifier for this deployment
     * @return storageContract Address of deployed storage contract
     * @return coreContract Address of deployed core contract
     * @return extensionsContract Address of deployed extensions contract
     * @return routerContract Address of deployed router contract
     */
    function deployFullPoliDaoWithModules(
        address commissionWallet,
        address feeToken,
        address initialToken,
        string calldata systemName,
        ModuleAddresses calldata modules
    ) external returns (
        uint256 deploymentId,
        address storageContract,
        address coreContract,
        address extensionsContract,
        address routerContract
    ) {
        // Deploy base system
        (
            deploymentId,
            storageContract,
            coreContract,
            extensionsContract,
            routerContract
        ) = deployFullPoliDao(
            commissionWallet,
            feeToken,
            initialToken,
            systemName
        );
        
        // Configure modules
        configureModules(deploymentId, modules);
        
        return (
            deploymentId,
            storageContract,
            coreContract,
            extensionsContract,
            routerContract
        );
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Gets information about a deployed system
     * @param deploymentId The deployment ID
     * @return system Deployed system information
     */
    function getDeployedSystem(uint256 deploymentId) 
        external 
        view 
        returns (DeployedSystem memory system) 
    {
        require(deploymentId <= deployedSystemsCount && deploymentId > 0, "PoliDaoFactory: Invalid deployment ID");
        return deployedSystems[deploymentId];
    }
    
    /**
     * @notice Gets all systems deployed by a specific address
     * @param deployer The deployer address
     * @return systemIds Array of deployment IDs
     */
    function getDeployerSystems(address deployer) 
        external 
        view 
        returns (uint256[] memory systemIds) 
    {
        return deployerSystems[deployer];
    }
    
    /**
     * @notice Gets the latest deployment by a deployer
     * @param deployer The deployer address
     * @return deploymentId Latest deployment ID (0 if none)
     * @return system Latest deployed system information
     */
    function getLatestDeployment(address deployer) 
        external 
        view 
        returns (uint256 deploymentId, DeployedSystem memory system) 
    {
        uint256[] memory systems = deployerSystems[deployer];
        if (systems.length == 0) {
            return (0, DeployedSystem({
                deployer: address(0),
                storageContract: address(0),
                coreContract: address(0),
                extensionsContract: address(0),
                routerContract: address(0),
                deploymentTime: 0,
                systemName: "",
                isConfigured: false
            }));
        }
        
        deploymentId = systems[systems.length - 1];
        system = deployedSystems[deploymentId];
        
        return (deploymentId, system);
    }
    
    /**
     * @notice Gets deployment statistics
     * @return totalDeployments Total number of systems deployed
     * @return configuredDeployments Number of fully configured systems
     * @return uniqueDeployers Number of unique deployer addresses
     */
    function getDeploymentStats() 
        external 
        view 
        returns (
            uint256 totalDeployments,
            uint256 configuredDeployments,
            uint256 uniqueDeployers
        ) 
    {
        totalDeployments = deployedSystemsCount;
        configuredDeployments = 0;
        
        // Count configured deployments
        for (uint256 i = 1; i <= deployedSystemsCount; i++) {
            if (deployedSystems[i].isConfigured) {
                configuredDeployments++;
            }
        }
        
        // Note: uniqueDeployers would require additional tracking
        // For now, we return 0 as placeholder
        uniqueDeployers = 0;
        
        return (totalDeployments, configuredDeployments, uniqueDeployers);
    }
    
    /**
     * @notice Validates if a deployment is fully functional
     * @param deploymentId The deployment ID
     * @return isValid Whether the deployment is valid and functional
     * @return issues Array of issue descriptions (if any)
     */
    function validateDeployment(uint256 deploymentId) 
        external 
        view 
        returns (bool isValid, string[] memory issues) 
    {
        require(deploymentId <= deployedSystemsCount && deploymentId > 0, "PoliDaoFactory: Invalid deployment ID");
        
        DeployedSystem memory system = deployedSystems[deploymentId];
        string[] memory tempIssues = new string[](10); // Max 10 issues
        uint256 issueCount = 0;
        
        // Check if contracts are deployed and have code
        if (!_hasCode(system.storageContract)) {
            tempIssues[issueCount] = "Storage contract has no code";
            issueCount++;
        }
        
        if (!_hasCode(system.coreContract)) {
            tempIssues[issueCount] = "Core contract has no code";
            issueCount++;
        }
        
        if (!_hasCode(system.extensionsContract)) {
            tempIssues[issueCount] = "Extensions contract has no code";
            issueCount++;
        }
        
        if (!_hasCode(system.routerContract)) {
            tempIssues[issueCount] = "Router contract has no code";
            issueCount++;
        }
        
        // Check if system is configured
        if (!system.isConfigured) {
            tempIssues[issueCount] = "System modules not configured";
            issueCount++;
        }
        
        // Check ownership
    try IStorageInit(system.storageContract).owner() returns (address storageOwner) {
            if (storageOwner != system.deployer) {
                tempIssues[issueCount] = "Storage ownership not transferred to deployer";
                issueCount++;
            }
        } catch {
            tempIssues[issueCount] = "Cannot verify storage ownership";
            issueCount++;
        }
        
    try ICoreInit(system.coreContract).owner() returns (address coreOwner) {
            if (coreOwner != system.deployer) {
                tempIssues[issueCount] = "Core ownership not transferred to deployer";
                issueCount++;
            }
        } catch {
            tempIssues[issueCount] = "Cannot verify core ownership";
            issueCount++;
        }
        
        // Create properly sized issues array
        issues = new string[](issueCount);
        for (uint256 i = 0; i < issueCount; i++) {
            issues[i] = tempIssues[i];
        }
        
        isValid = (issueCount == 0);
        
        return (isValid, issues);
    }
    
    // ========== UTILITY FUNCTIONS ==========
    
    /**
     * @notice Calculates deployment cost estimation
     * @return estimatedGas Estimated gas cost for deployment
     */
    function estimateDeploymentCost() external pure returns (uint256 estimatedGas) {
        // Rough estimation based on contract sizes
        // Storage: ~500k gas
        // Core: ~800k gas  
        // Extensions: ~600k gas
        // Router: ~400k gas
        // Configuration: ~200k gas
        return 2500000; // 2.5M gas estimation
    }
    
    /**
     * @notice Gets factory information
     * @return version Factory version
     * @return totalDeployments Number of deployments
     * @return contractAddress This factory's address
     */
    function getFactoryInfo() 
        external 
        view 
        returns (
            string memory version,
            uint256 totalDeployments,
            address contractAddress
        ) 
    {
        return (
            "1.0.0-UNIFIED",
            deployedSystemsCount,
            address(this)
        );
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @notice Checks if an address contains contract code
     * @param addr Address to check
     * @return hasCode Whether the address has code
     */
    function _hasCode(address addr) internal view returns (bool hasCode) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        return codeSize > 0;
    }
}