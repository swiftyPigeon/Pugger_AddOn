# Security

Found a way to forge someone's post, crash other players' clients, or abuse the feed in a way
its limits don't stop? Please report it **privately** through GitHub's private vulnerability
reporting (the repository's Security tab, "Report a vulnerability"), not in a public issue.

What Pugger promises: a post relayed by someone else shows only once its author's Ed25519
signature checks against the key heard directly from that author; every message from another
player is checked field by field and runs inside a crash guard; flood limits apply per sender.

What it can't promise: posts are public to everyone on the realm and faction with the add-on;
deleting isn't guaranteed; a modified client can lie about its own position in a group call (the
caller still sees the distance and decides).
