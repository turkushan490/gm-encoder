@echo off
REM ============================================================
REM  fix-author-history.bat
REM  Rewrites ALL commit authors to turkushan490 (single contributor).
REM  Force-pushes the rewritten history to origin.
REM
REM  WARNING: destructive, irreversible. Only safe for solo projects.
REM ============================================================

cd /d "%~dp0"
echo.
echo === Rewriting all commit authors to turkushan490 ===
echo.

REM Find git bash (filter-branch needs sh)
set "GITBASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not exist "%GITBASH%" (
    echo [!!] Git Bash not found at default location
    echo      Install Git for Windows from https://git-scm.com
    pause
    exit /b 1
)

REM Run filter-branch via bash
"%GITBASH%" -lc "cd '%~dp0' 2>/dev/null || cd \"$(cygpath -u '%~dp0')\" && export FILTER_BRANCH_SQUELCH_WARNING=1 && git filter-branch -f --env-filter 'NEW_NAME=turkushan490; NEW_EMAIL=1742126+turkushan490@users.noreply.github.com; if [ \"$GIT_COMMITTER_EMAIL\" = \"turkushan@gmail.com\" ] || [ \"$GIT_COMMITTER_EMAIL\" = \"oguzhan_karayurt@hotmail.com\" ]; then export GIT_COMMITTER_NAME=\"$NEW_NAME\"; export GIT_COMMITTER_EMAIL=\"$NEW_EMAIL\"; fi; if [ \"$GIT_AUTHOR_EMAIL\" = \"turkushan@gmail.com\" ] || [ \"$GIT_AUTHOR_EMAIL\" = \"oguzhan_karayurt@hotmail.com\" ]; then export GIT_AUTHOR_NAME=\"$NEW_NAME\"; export GIT_AUTHOR_EMAIL=\"$NEW_EMAIL\"; fi' --tag-name-filter cat -- --branches --tags"

if errorlevel 1 (
    echo [!!] filter-branch failed
    pause
    exit /b 2
)

echo.
echo === Verifying ===
git log --format="%%h ^| %%ae ^| %%an" -5
echo.

echo === Force pushing to origin ===
git push --force origin main
git push --force origin --tags

echo.
echo [OK] Done. All commits now show as turkushan490.
echo      Check https://github.com/turkushan490/gm-encoder/graphs/contributors
echo      (May take a few minutes for GitHub to update the contributor list)
pause
