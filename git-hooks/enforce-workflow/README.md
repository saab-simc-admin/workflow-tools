# WorkflowEnforcer

Git hook for enforcing various workflow properties, such as:

* All commits and tags are signed
* Signatures are made with authorised keys
* Master only accepts merges of feature branches
* Tags are not redefined

The hook is available in two forms, `pre-push` for local checks on the
client, to check that you aren't pushing something obviously wrong,
and `pre-receive` for server-side enforcement.

The `pre-push` hook does not validate signers, since that list is not
necessarily available on the client side. Signatures are still checked
for validity by GnuPG.


## Installation

Place `workflow_enforcer.rb` and the correct wrapper (`pre-push` on
clients, `pre-receive` on servers) in your Git hooks directory,
`.git/hooks/`.

For the server-side `pre-receive` hook, also place the
`collaborators.yaml` file in your `.git/` directory. This file should
contain a YAML hash from usernames to GnuPG key fingerprints
(40-character hex strings). Generate fingerprints by running `gpg
--fingerprint --with-colons <e-mail> | grep ^fpr | cut -d: -f 10`.


## Configuration

Git repository configuration can change what the hook allows. Set them
by running `git config <option> [true|false]`. The following options
are available:

Option | Default | Effect
------ | ------- | ------
hooks.allowunsignedcommits | `false` | Allow unsigned commits
hooks.allowunsignedtags | `false` | Allow unsigned tags
hooks.allowcommitsonmaster | `false` | Allow non-merge commits on `master`
hooks.allowunannotated | `false` | Allow un-annotated (and unsigned) tags
hooks.allowdeletetag | `false` | Allow deleting tags
hooks.allowmodifytag | `false` | Allow modifying tags
hooks.allowdeletebranch | `false` | Allow deleting branches
hooks.denycreatebranch | `false` | Deny creating branches
