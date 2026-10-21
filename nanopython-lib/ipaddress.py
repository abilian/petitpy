"""ipaddress — minimal PEP 3144 subset for the nanopython runtime.

Ships what hop3-rootd (and similar CIDR-validation code) actually
uses. Not a full ipaddress port. What's here:

    ip_address(value)                → IPv4Address | IPv6Address
    ip_network(value, strict=False)  → IPv4Network | IPv6Network
    IPv4Address, IPv6Address, IPv4Network, IPv6Network
        (int(addr), str(addr), str(net), .prefixlen, .network_address,
         .version, ==, hash — the surface isinstance-based CIDR code
         asks for)

What's missing (add on demand):

    hosts(), is_private, is_loopback, is_multicast, is_link_local,
    subnet_of(), supernet(), broadcast_address, netmask, hostmask,
    overlaps(), num_addresses, comparison operators between families,
    RFC 5952 canonical IPv6 form.

Design notes:

    IPv6 addresses are stored as a tuple of 8 uint16 groups rather
    than a 128-bit int. This lets the module import cleanly under
    nano configs that have no bignum (`MICROPY_LONGINT_IMPL=NONE`).
    IPv4 stays as a single 32-bit int — fits in every supported
    smallint size (62-bit on 64-bit native, 63-bit on wasm32
    longlong, unlimited on full mpz).
"""


# ── IPv4 ──────────────────────────────────────────────────────────────────


class IPv4Address:
    version = 4

    def __init__(self, packed):
        if isinstance(packed, str):
            packed = _v4_str_to_int(packed)
        elif isinstance(packed, int):
            if not 0 <= packed <= 0xFFFFFFFF:
                raise ValueError("IPv4 integer out of range: " + str(packed))
        else:
            raise ValueError("cannot construct IPv4Address from " + repr(packed))
        self._ip = packed

    def __int__(self):
        return self._ip

    def __str__(self):
        x = self._ip
        return "{}.{}.{}.{}".format(
            (x >> 24) & 0xFF, (x >> 16) & 0xFF, (x >> 8) & 0xFF, x & 0xFF
        )

    def __repr__(self):
        return "IPv4Address(" + repr(str(self)) + ")"

    def __eq__(self, other):
        return isinstance(other, IPv4Address) and self._ip == other._ip

    def __hash__(self):
        return hash((4, self._ip))


class IPv4Network:
    version = 4

    def __init__(self, address, prefixlen=None, strict=True):
        if isinstance(address, str) and prefixlen is None:
            if "/" in address:
                addr_s, _, prefix_s = address.partition("/")
                prefixlen = _parse_prefix(prefix_s, 32)
                packed = _v4_str_to_int(addr_s)
            else:
                packed = _v4_str_to_int(address)
                prefixlen = 32
        elif isinstance(address, IPv4Address):
            packed = int(address)
        elif isinstance(address, int):
            if not 0 <= address <= 0xFFFFFFFF:
                raise ValueError("IPv4 integer out of range: " + str(address))
            packed = address
        else:
            raise ValueError("cannot construct IPv4Network from " + repr(address))

        if prefixlen is None:
            prefixlen = 32
        if not 0 <= prefixlen <= 32:
            raise ValueError("IPv4 prefix out of range: " + str(prefixlen))

        host_bits = 32 - prefixlen
        if host_bits == 0:
            mask = 0xFFFFFFFF
        elif prefixlen == 0:
            mask = 0
        else:
            mask = 0xFFFFFFFF ^ ((1 << host_bits) - 1)
        masked = packed & mask
        if strict and masked != packed:
            raise ValueError(
                "host bits set: " + str(IPv4Address(packed)) + "/" + str(prefixlen)
            )

        self.network_address = IPv4Address(masked)
        self.prefixlen = prefixlen

    def __str__(self):
        return str(self.network_address) + "/" + str(self.prefixlen)

    def __repr__(self):
        return "IPv4Network(" + repr(str(self)) + ")"

    def __eq__(self, other):
        return (
            isinstance(other, IPv4Network)
            and self.network_address == other.network_address
            and self.prefixlen == other.prefixlen
        )

    def __hash__(self):
        return hash((4, int(self.network_address), self.prefixlen))


def _v4_str_to_int(s):
    if not isinstance(s, str):
        raise ValueError("IPv4 address must be a string, got " + repr(s))
    parts = s.split(".")
    if len(parts) != 4:
        raise ValueError("IPv4 needs 4 octets: " + repr(s))
    packed = 0
    for p in parts:
        if not p or len(p) > 3:
            raise ValueError("bad IPv4 octet " + repr(p) + " in " + repr(s))
        for ch in p:
            if not "0" <= ch <= "9":
                raise ValueError("non-digit in IPv4 octet " + repr(p))
        n = int(p)
        if n > 255:
            raise ValueError("IPv4 octet out of range: " + str(n))
        packed = (packed << 8) | n
    return packed


# ── IPv6 ──────────────────────────────────────────────────────────────────


class IPv6Address:
    version = 6

    def __init__(self, groups):
        if isinstance(groups, str):
            groups = _v6_str_to_groups(groups)
        if not isinstance(groups, tuple) or len(groups) != 8:
            raise ValueError("cannot construct IPv6Address from " + repr(groups))
        for g in groups:
            if not isinstance(g, int) or not 0 <= g <= 0xFFFF:
                raise ValueError("IPv6 group out of range: " + repr(g))
        self._groups = groups

    def __str__(self):
        # Not RFC 5952 canonical (no "::" compression), but round-trippable.
        return ":".join("{:x}".format(g) for g in self._groups)

    def __repr__(self):
        return "IPv6Address(" + repr(str(self)) + ")"

    def __eq__(self, other):
        return isinstance(other, IPv6Address) and self._groups == other._groups

    def __hash__(self):
        return hash((6, self._groups))


class IPv6Network:
    version = 6

    def __init__(self, address, prefixlen=None, strict=True):
        if isinstance(address, str) and prefixlen is None:
            if "/" in address:
                addr_s, _, prefix_s = address.partition("/")
                prefixlen = _parse_prefix(prefix_s, 128)
                groups = _v6_str_to_groups(addr_s)
            else:
                groups = _v6_str_to_groups(address)
                prefixlen = 128
        elif isinstance(address, IPv6Address):
            groups = address._groups
        elif isinstance(address, tuple):
            groups = address
        else:
            raise ValueError("cannot construct IPv6Network from " + repr(address))

        if prefixlen is None:
            prefixlen = 128
        if not 0 <= prefixlen <= 128:
            raise ValueError("IPv6 prefix out of range: " + str(prefixlen))

        # Group-wise mask — avoids constructing a 128-bit int.
        masked = list(groups)
        bits_left = prefixlen
        for i in range(8):
            if bits_left >= 16:
                bits_left -= 16
                continue
            if bits_left == 0:
                masked[i] = 0
                continue
            mask = 0xFFFF ^ ((1 << (16 - bits_left)) - 1)
            masked[i] = masked[i] & mask
            bits_left = 0
        masked_t = tuple(masked)
        if strict and masked_t != groups:
            raise ValueError("host bits set in IPv6 network")

        self.network_address = IPv6Address(masked_t)
        self.prefixlen = prefixlen

    def __str__(self):
        return str(self.network_address) + "/" + str(self.prefixlen)

    def __repr__(self):
        return "IPv6Network(" + repr(str(self)) + ")"

    def __eq__(self, other):
        return (
            isinstance(other, IPv6Network)
            and self.network_address == other.network_address
            and self.prefixlen == other.prefixlen
        )

    def __hash__(self):
        return hash((6, self.network_address._groups, self.prefixlen))


def _v6_str_to_groups(s):
    if not isinstance(s, str):
        raise ValueError("IPv6 address must be a string, got " + repr(s))
    if s.count("::") > 1:
        raise ValueError("multiple '::' in IPv6: " + repr(s))
    if "::" in s:
        head, _, tail = s.partition("::")
        head_g = head.split(":") if head else []
        tail_g = tail.split(":") if tail else []
        for g in head_g + tail_g:
            if g == "":
                raise ValueError("empty group in IPv6: " + repr(s))
        n_missing = 8 - len(head_g) - len(tail_g)
        if n_missing < 0:
            raise ValueError("too many groups in IPv6: " + repr(s))
        parts = head_g + ["0"] * n_missing + tail_g
    else:
        parts = s.split(":")
        if len(parts) != 8:
            raise ValueError("IPv6 needs 8 groups or '::': " + repr(s))
    out = []
    for g in parts:
        if not g or len(g) > 4:
            raise ValueError("bad IPv6 group " + repr(g) + " in " + repr(s))
        try:
            n = int(g, 16)
        except (ValueError, TypeError):
            raise ValueError("non-hex IPv6 group " + repr(g))
        out.append(n)
    return tuple(out)


# ── Factories ─────────────────────────────────────────────────────────────


def _parse_prefix(prefix_s, max_bits):
    try:
        n = int(prefix_s)
    except (ValueError, TypeError):
        raise ValueError("bad prefix length " + repr(prefix_s))
    if not 0 <= n <= max_bits:
        raise ValueError("prefix out of range: " + str(n))
    return n


def ip_address(value):
    if isinstance(value, (IPv4Address, IPv6Address)):
        return value
    if isinstance(value, str):
        if ":" in value:
            return IPv6Address(_v6_str_to_groups(value))
        return IPv4Address(_v4_str_to_int(value))
    if isinstance(value, int):
        if 0 <= value <= 0xFFFFFFFF:
            return IPv4Address(value)
        # >32-bit ints imply IPv6 under CPython. Our IPv6 layer takes
        # tuples/strings, not ints, so int→v6 stays unsupported.
        raise ValueError("IPv6 from int not supported: " + str(value))
    raise ValueError("cannot parse as IP address: " + repr(value))


def ip_network(value, strict=True):
    if isinstance(value, IPv4Network) or isinstance(value, IPv6Network):
        return value
    if isinstance(value, IPv4Address):
        return IPv4Network(value, 32, strict=strict)
    if isinstance(value, IPv6Address):
        return IPv6Network(value, 128, strict=strict)
    if isinstance(value, str):
        if ":" in value:
            return IPv6Network(value, strict=strict)
        return IPv4Network(value, strict=strict)
    if isinstance(value, int):
        if 0 <= value <= 0xFFFFFFFF:
            return IPv4Network(value, 32, strict=strict)
        raise ValueError("IPv6 from int not supported: " + str(value))
    raise ValueError("cannot parse as network: " + repr(value))
