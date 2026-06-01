# Initialiseert een Windows Job Object met KILL_ON_JOB_CLOSE.
# Alle child-processen die via Add-ToJob worden toegevoegd, worden
# automatisch gestopt zodra dit PowerShell-proces exit
# (ook bij hard sluiten van het cmd-window of Ctrl+C).
#
# Gebruik:
#   . "$PSScriptRoot\_job-kill-on-close.ps1"
#   [void]$proc.Start()
#   Add-ToJob $proc

if (-not ('W.Job' -as [type])) {
    Add-Type -Namespace W -Name Job -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit;
    public long PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
}
[StructLayout(LayoutKind.Sequential)]
public struct IO_COUNTERS {
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
}
[StructLayout(LayoutKind.Sequential)]
public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
}
[DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr CreateJobObject(IntPtr a, string lpName);
[DllImport("kernel32.dll")]
public static extern bool SetInformationJobObject(IntPtr hJob, int infoType, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);
[DllImport("kernel32.dll")]
public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
'@
}

# Maak globale job met KILL_ON_JOB_CLOSE (0x2000)
if (-not $script:__KillJob) {
    $script:__KillJob = [W.Job]::CreateJobObject([IntPtr]::Zero, $null)
    if ($script:__KillJob -ne [IntPtr]::Zero) {
        $info = New-Object W.Job+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        $info.BasicLimitInformation.LimitFlags = 0x2000   # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
        $ptr  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
        try {
            [System.Runtime.InteropServices.Marshal]::StructureToPtr($info, $ptr, $false)
            # 9 = JobObjectExtendedLimitInformation
            [void][W.Job]::SetInformationJobObject($script:__KillJob, 9, $ptr, [uint32]$size)
        } finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
        }
        # Voeg dit PowerShell-proces zelf toe aan de job. Vanaf nu erven ALLE
        # child processen (ook die met '&' worden gestart) automatisch deze job.
        try {
            $self = [System.Diagnostics.Process]::GetCurrentProcess()
            [void][W.Job]::AssignProcessToJobObject($script:__KillJob, $self.Handle)
        } catch {}
    }
}

# Houd een lijst van toegevoegde processen bij voor expliciete cleanup op Ctrl+C
$script:__TrackedProcs = New-Object System.Collections.ArrayList

function Add-ToJob {
    param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process)
    if ($script:__KillJob -and $script:__KillJob -ne [IntPtr]::Zero) {
        try { [void][W.Job]::AssignProcessToJobObject($script:__KillJob, $Process.Handle) } catch {}
    }
    [void]$script:__TrackedProcs.Add($Process)
}

function Stop-TrackedProcs {
    foreach ($p in $script:__TrackedProcs) {
        try {
            if (-not $p.HasExited) {
                $p.Kill($true)   # tree kill
            }
        } catch {}
    }
    $script:__TrackedProcs.Clear()
}

# Ctrl+C wordt door PowerShell zelf afgehandeld; bij script-exit sluit
# de job-handle automatisch en killt Windows alle child-processen.
# (Geen [Console]::CancelKeyPress hook - die werkt niet op static events in PS.)
