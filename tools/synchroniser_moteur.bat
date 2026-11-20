@echo off
rem Recopie le moteur Rust du Sursaut Windows dans ce dépôt (engine\sursaut-core).
rem A lancer depuis le dossier du dépôt iPad, puis tester (cargo test --workspace) et pousser.
set SRC=C:\Users\davca\Sursaut\core\src
set DST=%~dp0..\engine\sursaut-core\src
robocopy "%SRC%" "%DST%" *.rs /S /XD bin /NFL /NDL /NJH /NJS
echo Termine. Les fichiers bin\ (sursaut-render, sursaut-bench) ne sont pas copies.
echo Si le Cargo.toml du moteur a change (dependances), recopiez-le aussi a la main sans les blocs [[bin]].
