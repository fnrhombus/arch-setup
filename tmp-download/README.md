# tmp-download

Scratch folder for files Tom needs to sideload onto the Ventoy USB from his phone mid-install. Delete once the live install is done.

## autounattend.xml

Fixed copy of the repo-root `autounattend.xml` with Order 6 replaced to unblock the Win11 install (see PR #1 for context). Sideload this onto the **Ventoy** data partition, replacing the existing `autounattend.xml` at its root.
