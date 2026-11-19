# Vault auto-unseal key.
#
# Vault encrypts its data with a root key and starts "sealed": it cannot read anything until
# that key is supplied. With auto-unseal, Vault asks this KMS key to decrypt it at start-up,
# so a restarted pod comes back without a person typing unseal keys.

resource "aws_kms_key" "this" {
  description             = "Vault auto-unseal for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.cluster_name}-vault-unseal"
  target_key_id = aws_kms_key.this.key_id
}
