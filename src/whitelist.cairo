%lang starknet
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from cairo_contracts.src.openzeppelin.upgrades.library import Proxy
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address
from src.interface.naming import Naming
from src.interface.starknetid import StarknetId
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.math import assert_le_felt, split_felt
from starkware.cairo.common.uint256 import Uint256, uint256_unsigned_div_rem
from starkware.cairo.common.math_cmp import is_not_zero

// Storage 
@storage_var
func _naming_contract() -> (address: felt) {
}

@storage_var
func _starknetid_contract() -> (address: felt) {
}

@storage_var
func _admin_address() -> (address: felt) {
}

@storage_var
func _whitelisting_key() -> (whitelisting_key: felt) {
}

@storage_var
func _blacklisted_addresses(address: felt) -> (boolean: felt) {
}

@storage_var
func _is_registration_open() -> (boolean: felt) {
}

// Proxy 
@external
func initializer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    proxy_admin_address: felt, starknetid_contract: felt, naming_contract: felt, whitelist_key: felt
) {
    // Can only be called if there is no admin
    let (current_admin) = _admin_address.read();
    assert current_admin = 0;

    _admin_address.write(proxy_admin_address);
    _naming_contract.write(naming_contract);
    _starknetid_contract.write(starknetid_contract);

    // Whitelisting public key
    _whitelisting_key.write(whitelist_key);

    return ();
}

@external
func set_contracts{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    starknetid_contract: felt, naming_contract: felt
) {
    _check_admin();
    _naming_contract.write(naming_contract);
    _starknetid_contract.write(starknetid_contract);

    return ();
}

@external
func upgrade{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    new_implementation: felt
) {
    _check_admin();
    Proxy._set_implementation_hash(new_implementation);

    return ();
}

// External functions
@external
func claim_domain_back{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    domain_len: felt, domain: felt*
) {
    alloc_locals;

    // Check that the caller is the admin
    with_attr error_message("You are not the admin") {
        _check_admin();
    }

    // Get contracts addresses
    let (caller) = get_caller_address();
    let (current_contract, starknetid_contract, naming_contract) = _get_contracts_addresses();

    // Transfer back the starknet identity of the domain to the caller address
    let (token_id) = Naming.domain_to_token_id(naming_contract, domain_len, domain);
    let token_id_uint = Uint256(token_id, 0);
    StarknetId.transferFrom(starknetid_contract, current_contract, caller, token_id_uint);
    
    return ();
}

@external
func register{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, ecdsa_ptr: SignatureBuiltin*}(
    domain_len: felt, domain: felt*, receiver_token_id: felt, sig: (felt, felt)
) {
    alloc_locals;

    // Check if the registration is open
    let (is_registration_open) = _is_registration_open.read();
    with_attr error_message("The registration is closed") {
        assert is_registration_open = 1;
    } 


    // Check if name is more than 4 letters
    let (high, low) = split_felt(domain[0]);
    let uint256_domain = Uint256(low, high);
    let number_of_character = _get_amount_of_chars(uint256_domain);
    with_attr error_message("You can not register a og name with less than 4 characters.") {
        assert_le_felt(4, number_of_character);
    }


    // Check if the domain contains more than 3 characters
    with_attr error_message("You have to transfer a subdomain of the root domain, not the root domain itself.") {
        assert domain_len = 2;
    }

    // Verifiy that the caller address has not minted yet
    let (caller) = get_caller_address();
    let (is_blacklisted) = _blacklisted_addresses.read(caller);
    with_attr error_message("This address has already minted") {
        assert is_blacklisted = FALSE;
    }

    // Verify that the caller address is whitelisted
    let (whitelisting_key) = _whitelisting_key.read();
    with_attr error_message("You are not whitelisted") {
        verify_ecdsa_signature(caller, whitelisting_key, sig[0], sig[1]);
    }

    // Check if the name already has an address, as this contract will be the owner of the root domain it can transfer all the subdomain even if it does not own it
    with_attr error_message("This name is taken") {
        let (naming_contract) = _naming_contract.read();
        let (address) = Naming.domain_to_address(naming_contract, domain_len, domain);
        let is_name_taken = is_not_zero(address);
        assert is_name_taken = FALSE;
    }

    Naming.transfer_domain(naming_contract, domain_len, domain, receiver_token_id);

    // blacklist the address for this tokenId
    _blacklisted_addresses.write(caller, TRUE);

    return ();
}


//
// Admin functions
//

@external
func open_registration{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> () {
    _check_admin();
    _is_registration_open.write(1);

    return ();
}

@external
func close_registration{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> () {
    _check_admin();
    _is_registration_open.write(0);

    return ();
}

//
// View functions
//

@view
func is_registration_open{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (is_registration_open: felt) {
    let (is_registration_open) = _is_registration_open.read();

    return (is_registration_open,);
}

//
// Utils
//

func _check_admin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> () {
    let (caller) = get_caller_address();
    let (admin) = _admin_address.read();
    with_attr error_message("You can not call this function cause you are not the admin.") {
        assert caller = admin;
    }

    return ();
}

func _get_contracts_addresses{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() 
    -> (current_contract: felt, starknetid_contract: felt, naming_contract: felt) {

    let (current_contract) = get_contract_address();
    let (starknetid_contract) = _starknetid_contract.read();
    let (naming_contract) = _naming_contract.read();

    return (current_contract, starknetid_contract, naming_contract);
}

func _get_amount_of_chars{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    domain: Uint256
) -> felt {
    alloc_locals;
    if (domain.low == 0 and domain.high == 0) {
        return (0);
    }
    // 38 = simple_alphabet_size
    let (local p, q) = uint256_unsigned_div_rem(domain, Uint256(38, 0));
    if (q.high == 0 and q.low == 37) {
        // 3 = complex_alphabet_size
        let (shifted_p, _) = uint256_unsigned_div_rem(p, Uint256(2, 0));
        let next = _get_amount_of_chars(shifted_p);
        return 1 + next;
    }
    let next = _get_amount_of_chars(p);
    return 1 + next;
}



