# PGP Class Integration with Notebook to Decrypt `.pgp` File(s)
This process involves ingesting encrypted files into Delta Lake tables by leveraging an existing workflow that includes a conditional task for decrypting incoming files.

## Notebook 
`den_nbk_pdi_001_ingest_curated`
### Required libraries:
```py
from spark_engine.common.pgp import PGP
import fsspec
```

### Parameters for PGP decryption from dataset file

```json
 "sourceSystemProperties": {
        "pgpEnabled": true,
        "privateKeySecret": "distro-delauth-private-key-pgp",
        "passphraseSecret": "distro-delauth-passphrase-pgp",
        "publicKeySecret": "distro-delauth-ftp-public-key-pgp"
    }
```
## Function
`decrypt_file`

```py
def decrypt_file(
    input_folder: str,
    output_path: str,
    key_vault_name: str = None,
    private_key_secret: str = None,
    public_key_secret: str = None,
    passphrase_secret: str = None
) -> None:
    if key_vault_name is None or private_key_secret is None:
        raise ValueError("key_vault_name and private_key_secret must be provided when pgp_enabled is True.")

     # Initialize fsspec filesystem for OneLake
    fs = fsspec.filesystem(
        "abfss",
        account_name="onelake",
        account_host="onelake.dfs.fabric.microsoft.com"
    )

    # Check if the input folder exists
    if not fs.exists(input_folder):
        raise FileNotFoundError(f"Input folder not found: {input_folder}")

    # List files in the input folder and filter for .pgp extension
    files = [f for f in fs.ls(input_folder, detail=False) if f.lower().endswith(".pgp")]
    if not files:
        raise ValueError(f"No .pgp files found in {input_folder}")

    # Initialize PGP class
    pgp = PGP(
        key_vault_name=key_vault_name,
        public_key_secret=public_key_secret,
        private_key_secret=private_key_secret,
        passphrase_secret=passphrase_secret
    )
    
    # Decrypt each .pgp file
    for input_file in files:
        try:
            input_file = f"abfss://{input_file}"
            pgp.decrypt_file(
                input_file=input_file,
                output_path=output_path
            )
            print(f"File {input_file} decrypted successfully to {output_path}")
        except Exception as e:
            print(f"Failed to decrypt {input_file}: {str(e)}")
            raise IOError(f"Failed to decrypt {input_file}: {str(e)}")
```
## Usage Example
```py
# check if PGP encryption enabled and private key secret for decryption
pgp_enabled = metadata_config_dict["sourceSystemProperties"].get("pgpEnabled")
key_vault_name = secretsScope
if pgp_enabled:
    print("PGP enabled, trying to decrypt file(s)...")
    private_key_secret = metadata_config_dict["sourceSystemProperties"].get("privateKeySecret")
    passphrase_secret = metadata_config_dict["sourceSystemProperties"].get("passphraseSecret")
    public_key_secret = metadata_config_dict["sourceSystemProperties"].get("publicKeySecret")
    if private_key_secret is None or key_vault_name is None or passphrase_secret is None:
        raise ValueError("key_vault_name, private_key_secret and passphrase_secret must be provided when pgpEnabled is True.")

    # construct decrypted path
    output_path = f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{lh_raw_id}/Files/{dataset_file_name}/decrypted/{run_id}"
    decrypt_file(
        input_folder=data_location,
        output_path=output_path,
        key_vault_name=key_vault_name,
        private_key_secret=private_key_secret,
        passphrase_secret=passphrase_secret,
        public_key_secret=public_key_secret
    )
```
