#requires -Version 5.1
<#
  gm-encoder.ps1
  GM Encoder GUI - WPF in PowerShell.
  Wraps Encoder.psm1 with a blue-themed interactive interface.
#>

[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = 'Stop'

try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

$ErrorLogPath = $null
function Write-StartupError {
    param([System.Management.Automation.ErrorRecord]$Err, [string]$Where = 'startup')
    $msg = @"
[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] FATAL @ $Where
Message:    $($Err.Exception.Message)
Type:       $($Err.Exception.GetType().FullName)
Line:       $($Err.InvocationInfo.ScriptLineNumber) col $($Err.InvocationInfo.OffsetInLine)
Command:    $($Err.InvocationInfo.Line)
Position:   $($Err.InvocationInfo.PositionMessage)
StackTrace: $($Err.ScriptStackTrace)
Inner:      $($Err.Exception.InnerException)
"@
    if ($ErrorLogPath) {
        try { Add-Content -LiteralPath $ErrorLogPath -Value "$msg`n--`n" -ErrorAction SilentlyContinue } catch {}
    }
    return $msg
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Resolve-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) {
        return Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath) { return [System.IO.Path]::GetDirectoryName($exePath) }
    } catch {}
    return (Get-Location).Path
}
$script:Root = Resolve-ScriptRoot
$ErrorLogPath = Join-Path $script:Root 'gm-encoder-error.log'

trap {
    $msg = Write-StartupError -Err $_ -Where 'trap'
    try {
        [System.Windows.MessageBox]::Show(
            "$msg`n`nFull log:`n$ErrorLogPath",
            'GM Encoder - Fatal',
            'OK',
            'Error'
        ) | Out-Null
    } catch {
        Write-Host $msg
    }
    exit 1
}

Get-ChildItem -Path (Join-Path $Root 'gui') -Recurse -Include '*.ps1','*.psm1' -ErrorAction SilentlyContinue |
    ForEach-Object { try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {} }

$encoderModulePath = Join-Path $Root 'gui\Encoder.psm1'
if (-not (Test-Path -LiteralPath $encoderModulePath)) {
    [System.Windows.MessageBox]::Show(
        "Encoder.psm1 not found at:`n$encoderModulePath",
        'GM Encoder - Module missing',
        'OK', 'Error'
    ) | Out-Null
    exit 1
}
Import-Module $encoderModulePath -Force

# =============================================================
# XAML
# =============================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GM Encoder"
        Width="1340" Height="860"
        WindowStartupLocation="CenterScreen"
        Background="Transparent">
    <Window.Resources>
        <!-- Lichter blauwe radiale achtergrond -->
        <RadialGradientBrush x:Key="BlueBg" Center="0.5,0.3" RadiusX="1.0" RadiusY="1.0">
            <GradientStop Color="#FF3B6BC8" Offset="0"/>
            <GradientStop Color="#FF1E3A8A" Offset="0.55"/>
            <GradientStop Color="#FF0F2150" Offset="1"/>
        </RadialGradientBrush>
        <SolidColorBrush x:Key="AccentBlue"    Color="#FF60A5FA"/>
        <SolidColorBrush x:Key="AccentBlueDim" Color="#FF3B82F6"/>
        <SolidColorBrush x:Key="DangerRed"     Color="#FFEF4444"/>
        <SolidColorBrush x:Key="WarnAmber"     Color="#FFF59E0B"/>
        <SolidColorBrush x:Key="PanelBg"       Color="#33FFFFFF"/>
        <SolidColorBrush x:Key="PanelBgDark"   Color="#221E3A8A"/>
        <SolidColorBrush x:Key="ConsoleBg"     Color="#FF000814"/>
        <SolidColorBrush x:Key="WhiteSoft"     Color="#FFEEF4FF"/>
        <SolidColorBrush x:Key="WhiteDim"      Color="#FFB4C6E7"/>

        <Style TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBlue}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF93C5FD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FF93C5FD"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#FF1E3A5F"/>
                    <Setter Property="Foreground" Value="#FF607090"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource DangerRed}"/>
            <Setter Property="BorderBrush" Value="#FFFCA5A5"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FFF87171"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="WarnButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource WarnAmber}"/>
            <Setter Property="BorderBrush" Value="#FFFCD34D"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FFFBBF24"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource WhiteSoft}"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource WhiteSoft}"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource WhiteSoft}"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="Black"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="MinWidth" Value="280"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#FF1B2D5A"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF60A5FA"/>
            <Setter Property="Padding" Value="4,3"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#22FFFFFF"/>
            <Setter Property="Foreground" Value="{StaticResource WhiteSoft}"/>
            <Setter Property="BorderBrush" Value="#FF60A5FA"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="Expander">
            <Setter Property="Foreground" Value="{StaticResource WhiteSoft}"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
    </Window.Resources>

    <Border Background="{StaticResource BlueBg}">
        <Grid Margin="14">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>  <!-- Setup -->
                <RowDefinition Height="*"/>     <!-- Main 3-col -->
                <RowDefinition Height="Auto"/>  <!-- Progress bars -->
                <RowDefinition Height="170"/>   <!-- Console -->
            </Grid.RowDefinitions>

            <!-- ============================================ -->
            <!-- ROW 0: SETUP PANEL                            -->
            <!-- ============================================ -->
            <Border x:Name="SetupPanel" Grid.Row="0" Background="{StaticResource PanelBgDark}"
                    CornerRadius="8" Padding="16" Margin="0,0,0,10">
                <StackPanel>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock Text="GM Encoder" FontSize="24" FontWeight="Bold" Margin="0,0,16,0" VerticalAlignment="Center"/>
                            <Button x:Name="BtnInstall"   Content="Install"   MinWidth="80" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <Button x:Name="BtnReinstall" Content="Reinstall" MinWidth="80" Margin="0,0,0,0" VerticalAlignment="Center" Style="{StaticResource WarnButton}"/>
                        </StackPanel>

                        <!-- CPU/GPU mini-bars + Pause/Stop in header rechts -->
                        <StackPanel Grid.Column="1" Orientation="Vertical" VerticalAlignment="Center" Margin="0,0,16,0" MinWidth="180">
                            <Grid Margin="0,0,0,3">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="32"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="38"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="CPU" FontSize="10" Foreground="{StaticResource WhiteDim}" VerticalAlignment="Center"/>
                                <Grid Grid.Column="1" Height="10" Margin="0,0,4,0">
                                    <Border Background="#FF0A1428" CornerRadius="2" BorderBrush="#55F59E0B" BorderThickness="1"/>
                                    <Border x:Name="CpuWaveContainer" HorizontalAlignment="Left" Background="#FFFBBF24" CornerRadius="2,0,0,2" Width="0"/>
                                </Grid>
                                <TextBlock Grid.Column="2" x:Name="LblCpuVal" Text="0%" FontSize="10" Foreground="{StaticResource WhiteDim}" FontFamily="Consolas" VerticalAlignment="Center" TextAlignment="Right"/>
                            </Grid>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="32"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="38"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="GPU" FontSize="10" Foreground="{StaticResource WhiteDim}" VerticalAlignment="Center"/>
                                <Grid Grid.Column="1" Height="10" Margin="0,0,4,0">
                                    <Border Background="#FF0A1428" CornerRadius="2" BorderBrush="#55A78BFA" BorderThickness="1"/>
                                    <Border x:Name="GpuWaveContainer" HorizontalAlignment="Left" Background="#FFA78BFA" CornerRadius="2,0,0,2" Width="0"/>
                                </Grid>
                                <TextBlock Grid.Column="2" x:Name="LblGpuVal" Text="0%" FontSize="10" Foreground="{StaticResource WhiteDim}" FontFamily="Consolas" VerticalAlignment="Center" TextAlignment="Right"/>
                            </Grid>
                        </StackPanel>

                        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="BtnPause" Content="Pause" Style="{StaticResource WarnButton}" Visibility="Collapsed" MinWidth="80" Margin="0,0,8,0"/>
                            <Button x:Name="BtnStop"  Content="Stop"  Style="{StaticResource DangerButton}" Visibility="Collapsed" MinWidth="80" Margin="0,0,8,0"/>
                        </StackPanel>
                    </Grid>

                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="120"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Label    Grid.Row="0" Grid.Column="0" Content="Input folder:"/>
                        <TextBox  x:Name="TxtInput"  Grid.Row="0" Grid.Column="1" Margin="0,3"/>
                        <Button   x:Name="BtnPickInput" Grid.Row="0" Grid.Column="2" Content="Browse..." Margin="6,3,0,3"/>

                        <Label    Grid.Row="1" Grid.Column="0" Content="Output folder:"/>
                        <TextBox  x:Name="TxtOutput" Grid.Row="1" Grid.Column="1" Margin="0,3"/>
                        <Button   x:Name="BtnPickOutput" Grid.Row="1" Grid.Column="2" Content="Browse..." Margin="6,3,0,3"/>

                        <Label    Grid.Row="2" Grid.Column="0" Content="Codec:"/>
                        <ComboBox x:Name="CmbCodec"  Grid.Row="2" Grid.Column="1" Margin="0,3" HorizontalAlignment="Left" MinWidth="380"/>

                        <StackPanel Grid.Row="3" Grid.Column="1" Orientation="Horizontal" Margin="0,10,0,0">
                            <CheckBox x:Name="ChkOptimize" Content="Optimize (VMAF search)" IsChecked="True" VerticalAlignment="Center" Margin="0,0,24,0"/>
                            <CheckBox x:Name="ChkDelete"   Content="Move source to done folder (remove from input)" VerticalAlignment="Center" Margin="0,0,24,0"/>
                            <CheckBox x:Name="ChkPermanent" Content="Permanently delete file" VerticalAlignment="Center" IsEnabled="False" Foreground="#FFFCA5A5"/>
                        </StackPanel>
                    </Grid>

                    <!-- Optimize settings: altijd zichtbaar (VMAF target + Tolerance) -->
                    <Grid Margin="0,12,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="120"/>
                            <ColumnDefinition Width="90"/>
                            <ColumnDefinition Width="20"/>
                            <ColumnDefinition Width="120"/>
                            <ColumnDefinition Width="90"/>
                            <ColumnDefinition Width="20"/>
                            <ColumnDefinition Width="120"/>
                            <ColumnDefinition Width="90"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Label   Grid.Column="0" Content="VMAF target:"/>
                        <TextBox x:Name="TxtVmaf"      Grid.Column="1" Text="93"/>
                        <Label   Grid.Column="3" Content="Tolerance:"/>
                        <TextBox x:Name="TxtTolerance" Grid.Column="4" Text="1.5"/>
                        <Label   Grid.Column="6" Content="Height (px):"/>
                        <TextBox x:Name="TxtHeight"    Grid.Column="7" Text="0"/>
                    </Grid>

                    <Expander x:Name="ExpManual" Header="Manual encoding settings (active when Optimize is off)" Margin="0,8,0,0" IsExpanded="False">
                        <Grid Margin="20,10,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="140"/>
                                <ColumnDefinition Width="90"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Label   Grid.Column="0" Content="CRF / QP:"/>
                            <TextBox x:Name="TxtCrf"   Grid.Column="1" Text="23"/>
                        </Grid>
                    </Expander>

                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
                        <Button x:Name="BtnRescan" Content="Refresh input" Margin="0,0,8,0"/>
                        <Button x:Name="BtnStart" Content="START" FontSize="16" FontWeight="Bold" Padding="24,6"/>
                    </StackPanel>
                </StackPanel>
            </Border>

            <!-- ============================================ -->
            <!-- ROW 1: 3-COLUMN MAIN                          -->
            <!-- ============================================ -->
            <Grid Grid.Row="1" Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Background="{StaticResource PanelBgDark}" CornerRadius="8" Padding="10" Margin="0,0,5,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="Queue" FontSize="15" FontWeight="Bold" Margin="0,0,0,6"/>
                        <ListBox x:Name="LstPending" Grid.Row="1">
                            <ListBox.ItemTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal" Margin="2">
                                        <Ellipse Width="11" Height="11" VerticalAlignment="Center" Margin="0,0,8,0">
                                            <Ellipse.Style>
                                                <Style TargetType="Ellipse">
                                                    <Setter Property="Fill" Value="#FF6B7280"/>
                                                    <Style.Triggers>
                                                        <DataTrigger Binding="{Binding Status}" Value="Probing">
                                                            <Setter Property="Fill" Value="#FFFBBF24"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="Sampling">
                                                            <Setter Property="Fill" Value="#FFFBBF24"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="SceneDetect">
                                                            <Setter Property="Fill" Value="#FFFBBF24"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="Searching">
                                                            <Setter Property="Fill" Value="#FF60A5FA"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="Encoding">
                                                            <Setter Property="Fill" Value="#FF60A5FA"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="Muxing">
                                                            <Setter Property="Fill" Value="#FF22C55E"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="Failed">
                                                            <Setter Property="Fill" Value="{StaticResource DangerRed}"/>
                                                        </DataTrigger>
                                                    </Style.Triggers>
                                                </Style>
                                            </Ellipse.Style>
                                        </Ellipse>
                                        <StackPanel>
                                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold"/>
                                            <TextBlock Text="{Binding StatusText}" FontSize="11" Foreground="{StaticResource WhiteDim}"/>
                                        </StackPanel>
                                    </StackPanel>
                                </DataTemplate>
                            </ListBox.ItemTemplate>
                        </ListBox>
                    </Grid>
                </Border>

                <Border Grid.Column="1" Background="{StaticResource PanelBgDark}" CornerRadius="8" Padding="14" Margin="5,0,5,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="Details" FontSize="15" FontWeight="Bold" Margin="0,0,0,10"/>
                        <StackPanel x:Name="PnlDetails" Grid.Row="1">
                            <TextBlock x:Name="DetEmpty" Text="Click a completed file on the right to see details."
                                       Foreground="{StaticResource WhiteDim}" TextWrapping="Wrap"/>
                            <Grid x:Name="DetContent" Visibility="Collapsed">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="120"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Label Grid.Row="0" Grid.Column="0" Content="File:"/>
                                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="DetName" TextWrapping="Wrap" VerticalAlignment="Center"/>
                                <Label Grid.Row="1" Grid.Column="0" Content="Codec:"/>
                                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="DetCodec" VerticalAlignment="Center"/>
                                <Label Grid.Row="2" Grid.Column="0" Content="CRF / quality:"/>
                                <TextBlock Grid.Row="2" Grid.Column="1" x:Name="DetCrf" VerticalAlignment="Center"/>
                                <Label Grid.Row="3" Grid.Column="0" Content="VMAF:"/>
                                <TextBlock Grid.Row="3" Grid.Column="1" x:Name="DetVmaf" VerticalAlignment="Center"/>
                                <Label Grid.Row="4" Grid.Column="0" Content="Input size:"/>
                                <TextBlock Grid.Row="4" Grid.Column="1" x:Name="DetSizeIn" VerticalAlignment="Center"/>
                                <Label Grid.Row="5" Grid.Column="0" Content="Output size:"/>
                                <TextBlock Grid.Row="5" Grid.Column="1" x:Name="DetSizeOut" VerticalAlignment="Center"/>
                                <Label Grid.Row="6" Grid.Column="0" Content="Ratio:"/>
                                <TextBlock Grid.Row="6" Grid.Column="1" x:Name="DetRatio" VerticalAlignment="Center" FontWeight="Bold"/>
                                <Label Grid.Row="7" Grid.Column="0" Content="Duration:"/>
                                <TextBlock Grid.Row="7" Grid.Column="1" x:Name="DetTime" VerticalAlignment="Center"/>
                                <Label Grid.Row="8" Grid.Column="0" Content="Path:"/>
                                <TextBlock Grid.Row="8" Grid.Column="1" x:Name="DetPath" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="11" Foreground="{StaticResource WhiteDim}"/>
                            </Grid>
                        </StackPanel>
                    </Grid>
                </Border>

                <Border Grid.Column="2" Background="{StaticResource PanelBgDark}" CornerRadius="8" Padding="10" Margin="5,0,0,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="Completed" FontSize="15" FontWeight="Bold" Margin="0,0,0,6"/>
                        <ListBox x:Name="LstCompleted" Grid.Row="1">
                            <ListBox.ItemTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal" Margin="2">
                                        <Ellipse Width="11" Height="11" VerticalAlignment="Center" Margin="0,0,8,0" Fill="#FF22C55E"/>
                                        <StackPanel>
                                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold"/>
                                            <TextBlock FontSize="11" Foreground="{StaticResource WhiteDim}">
                                                <Run Text="{Binding SizeIn, StringFormat={}{0} MB}"/>
                                                <Run Text=" -> "/>
                                                <Run Text="{Binding SizeOut, StringFormat={}{0} MB}"/>
                                                <Run Text=" ("/>
                                                <Run Text="{Binding Ratio, StringFormat={}{0}%}"/>
                                                <Run Text=")"/>
                                            </TextBlock>
                                        </StackPanel>
                                    </StackPanel>
                                </DataTemplate>
                            </ListBox.ItemTemplate>
                        </ListBox>
                    </Grid>
                </Border>
            </Grid>

            <!-- ============================================ -->
            <!-- ROW 2: PROGRESS BARS (Overall + Step, geen waves) -->
            <!-- ============================================ -->
            <Border Grid.Row="2" Background="{StaticResource PanelBgDark}" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                <StackPanel>
                    <Grid Margin="0,0,0,4">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" x:Name="LblPhase" Text="Idle" FontWeight="SemiBold" FontSize="13"/>
                        <TextBlock Grid.Column="1" x:Name="LblStats" Text="" Foreground="{StaticResource WhiteDim}"/>
                    </Grid>

                    <!-- Bar 1: OVERALL FILE PROGRESS (groen, solid fill) -->
                    <TextBlock Text="Overall file progress" FontSize="11" Foreground="{StaticResource WhiteDim}" Margin="0,2,0,2"/>
                    <Grid Height="22" Margin="0,0,0,8">
                        <Border Background="#FF0A1428" CornerRadius="4" BorderBrush="#553B82F6" BorderThickness="1"/>
                        <Border x:Name="WaveContainer" HorizontalAlignment="Left" CornerRadius="4,0,0,4" Width="0">
                            <Border.Background>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                    <GradientStop Color="#FF16A34A" Offset="0"/>
                                    <GradientStop Color="#FF22C55E" Offset="1"/>
                                </LinearGradientBrush>
                            </Border.Background>
                        </Border>
                        <TextBlock x:Name="LblPct" Text="0%" HorizontalAlignment="Center" VerticalAlignment="Center"
                                   Foreground="White" FontWeight="Bold" FontFamily="Consolas"/>
                    </Grid>

                    <!-- Bar 2: CURRENT STEP PROGRESS (blauw, solid fill) -->
                    <TextBlock x:Name="LblStepName" Text="Step: (idle)" FontSize="11" Foreground="{StaticResource WhiteDim}" Margin="0,0,0,2"/>
                    <Grid Height="18">
                        <Border Background="#FF0A1428" CornerRadius="3" BorderBrush="#553B82F6" BorderThickness="1"/>
                        <Border x:Name="StepWaveContainer" HorizontalAlignment="Left" CornerRadius="3,0,0,3" Width="0">
                            <Border.Background>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                    <GradientStop Color="#FF3B82F6" Offset="0"/>
                                    <GradientStop Color="#FF60A5FA" Offset="1"/>
                                </LinearGradientBrush>
                            </Border.Background>
                        </Border>
                        <TextBlock x:Name="LblStepPct" Text="" HorizontalAlignment="Center" VerticalAlignment="Center"
                                   Foreground="White" FontWeight="Bold" FontFamily="Consolas" FontSize="11"/>
                    </Grid>
                </StackPanel>
            </Border>

            <!-- ============================================ -->
            <!-- ROW 3: CONSOLE                                -->
            <!-- ============================================ -->
            <Border Grid.Row="3" Background="{StaticResource ConsoleBg}" CornerRadius="8"
                    BorderBrush="#553B82F6" BorderThickness="1">
                <RichTextBox x:Name="Console" IsReadOnly="True" Background="Transparent"
                             Foreground="#FFCFE0FF" FontFamily="Consolas" FontSize="11"
                             BorderThickness="0" Padding="8"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
                    <FlowDocument PagePadding="0">
                        <Paragraph x:Name="ConsoleParagraph" Margin="0"/>
                    </FlowDocument>
                </RichTextBox>
            </Border>
        </Grid>
    </Border>
</Window>
'@

[xml]$xamlDoc = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
$window = [Windows.Markup.XamlReader]::Load($reader)

# Set window icon - tries multiple locations so it works in dev + bundled exe
foreach ($icoPath in @(
    (Join-Path $Root 'docs\icon.ico'),
    (Join-Path $Root 'icon.ico'),
    (Join-Path ([System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)) 'docs\icon.ico')
)) {
    if ($icoPath -and (Test-Path -LiteralPath $icoPath)) {
        try {
            $uri = New-Object System.Uri ($icoPath, [System.UriKind]::Absolute)
            $window.Icon = New-Object System.Windows.Media.Imaging.BitmapImage $uri
            break
        } catch {}
    }
}

function Get-Ctrl([string]$name) { return $window.FindName($name) }

$ctrl = @{}
foreach ($n in @(
    'SetupPanel','TxtInput','TxtOutput','BtnPickInput','BtnPickOutput',
    'CmbCodec','ChkOptimize','ChkDelete','ChkPermanent','ExpManual',
    'TxtCrf','TxtHeight','TxtVmaf','TxtTolerance',
    'BtnRescan','BtnStart','BtnPause','BtnStop','BtnInstall','BtnReinstall',
    'LstPending','LstCompleted',
    'PnlDetails','DetEmpty','DetContent',
    'DetName','DetCodec','DetCrf','DetVmaf','DetSizeIn','DetSizeOut','DetRatio','DetTime','DetPath',
    'LblPhase','LblStats','LblPct',
    'WaveContainer',
    'LblStepName','LblStepPct','StepWaveContainer',
    'LblCpuVal','CpuWaveContainer',
    'LblGpuVal','GpuWaveContainer',
    'Console','ConsoleParagraph'
)) { $ctrl[$n] = Get-Ctrl $n }

$paths = Get-AsaPaths -BaseDir $Root
$ctrl.TxtInput.Text  = $paths.Input
$ctrl.TxtOutput.Text = $paths.Output

# Fill codec dropdown
$ffmpegAvailable = Test-Path $paths.Ffmpeg
$encStatus = @{}
if ($ffmpegAvailable) { $encStatus = Get-AvailableEncoders -FfmpegPath $paths.Ffmpeg }

foreach ($c in Get-CodecList) {
    $ok = if ($ffmpegAvailable -and $encStatus[$c.Codec]) { '[OK]' } else { '[--]' }
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = "$ok  $($c.Display)  ($($c.Codec))"
    $item.Tag = $c.Codec
    [void]$ctrl.CmbCodec.Items.Add($item)
}
$ctrl.CmbCodec.SelectedIndex = 7  # default = libx265

# Geen wave animaties - simpele solid color fill bars (geen stutter, geen CPU overhead)

# =============================================================
# State
# =============================================================
$script:Pending   = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$script:Completed = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$ctrl.LstPending.ItemsSource   = $script:Pending

# =============================================================
# Settings persistence (JSON in %APPDATA%\GmEncoder\)
# =============================================================
$script:SettingsDir  = Join-Path $env:APPDATA 'GmEncoder'
$script:SettingsFile = Join-Path $script:SettingsDir 'settings.json'
if (-not (Test-Path -LiteralPath $script:SettingsDir)) {
    try { New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null } catch {}
}

function Save-Settings {
    try {
        $data = @{
            InputDir   = "$($ctrl.TxtInput.Text)"
            OutputDir  = "$($ctrl.TxtOutput.Text)"
            CodecIndex = [int]$ctrl.CmbCodec.SelectedIndex
            Optimize   = [bool]$ctrl.ChkOptimize.IsChecked
            Delete     = [bool]$ctrl.ChkDelete.IsChecked
            Permanent  = [bool]$ctrl.ChkPermanent.IsChecked
            Vmaf       = "$($ctrl.TxtVmaf.Text)"
            Tolerance  = "$($ctrl.TxtTolerance.Text)"
            Height     = "$($ctrl.TxtHeight.Text)"
            Crf        = "$($ctrl.TxtCrf.Text)"
        }
        ($data | ConvertTo-Json -Compress) | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch {}
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) { return }
    try {
        $data = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json
        if ($data.InputDir)   { $ctrl.TxtInput.Text  = $data.InputDir }
        if ($data.OutputDir)  { $ctrl.TxtOutput.Text = $data.OutputDir }
        if ($data.CodecIndex -is [int] -and $data.CodecIndex -ge 0 -and $data.CodecIndex -lt $ctrl.CmbCodec.Items.Count) {
            $ctrl.CmbCodec.SelectedIndex = [int]$data.CodecIndex
        }
        $ctrl.ChkOptimize.IsChecked  = [bool]$data.Optimize
        $ctrl.ChkDelete.IsChecked    = [bool]$data.Delete
        $ctrl.ChkPermanent.IsEnabled = [bool]$data.Delete
        $ctrl.ChkPermanent.IsChecked = [bool]$data.Permanent
        if ($data.Vmaf)      { $ctrl.TxtVmaf.Text      = "$($data.Vmaf)" }
        if ($data.Tolerance) { $ctrl.TxtTolerance.Text = "$($data.Tolerance)" }
        if ($data.Height -ne $null) { $ctrl.TxtHeight.Text = "$($data.Height)" }
        if ($data.Crf)       { $ctrl.TxtCrf.Text       = "$($data.Crf)" }
    } catch {}
}
$ctrl.LstCompleted.ItemsSource = $script:Completed

$script:LogQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:Running  = $false
$script:Paused   = $false
$script:StopRequested = $false

# Shared state tussen worker en UI thread - WORKER ALLEEN SCHRIJVEN, UI ALLEEN LEZEN
# Thread-safe via Hashtable.Synchronized
$script:SharedState = [System.Collections.Hashtable]::Synchronized(@{
    OverallPct  = 0
    OverallText = ''
    StepPct     = 0
    StepName    = ''
    PhaseLabel  = 'Idle'
    StatsText   = ''
    Dirty       = $false   # signaal: er is iets om te updaten
})

# Live CPU/GPU usage (separate, ge-updated door UI-thread sampling timer)
$script:HwUsage = @{ Cpu = 0; Gpu = 0 }

# Concurrent queue voor file state changes (move pending->completed)
$script:UiActionQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[hashtable]

# =============================================================
# UI Helpers
# =============================================================
function Add-ConsoleLine {
    param([string]$Text)
    if (-not $Text) { return }
    $color = '#FFCFE0FF'
    if ($Text -match '^\[ERR\]|error|fail|panic')        { $color = '#FFFCA5A5' }
    elseif ($Text -match '^\[WARN\]|warn')               { $color = '#FFFCD34D' }
    elseif ($Text -match '^\[OK\]|completed|success')    { $color = '#FF86EFAC' }
    elseif ($Text -match '^\[INFO\]|level=INFO')         { $color = '#FF93C5FD' }
    elseif ($Text -match 'level=ERROR')                  { $color = '#FFFCA5A5' }
    elseif ($Text -match '^>|^  >|^\s+>')                { $color = '#FF94A3B8' }

    $run = New-Object System.Windows.Documents.Run
    $run.Text = $Text
    $run.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $ctrl.ConsoleParagraph.Inlines.Add($run)
    $ctrl.ConsoleParagraph.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $ctrl.Console.ScrollToEnd()

    while ($ctrl.ConsoleParagraph.Inlines.Count -gt 2000) {
        $first = $ctrl.ConsoleParagraph.Inlines | Select-Object -First 1
        if ($first) { $ctrl.ConsoleParagraph.Inlines.Remove($first) } else { break }
    }
}

function Set-OverallProgress {
    param([int]$Pct)
    $pctSafe = [Math]::Max(0, [Math]::Min(100, $Pct))
    $ctrl.LblPct.Text = "$pctSafe%"
    $parent = $ctrl.WaveContainer.Parent
    $maxW = if ($parent.ActualWidth -gt 0) { $parent.ActualWidth } else { 1200 }
    $ctrl.WaveContainer.Width = [Math]::Max(0, $maxW * $pctSafe / 100)
}

function Set-StepProgress {
    param([int]$Pct, [string]$StepName)
    $pctSafe = [Math]::Max(0, [Math]::Min(100, $Pct))
    if ($StepName) {
        $ctrl.LblStepName.Text = "Step: $StepName"
    }
    if ($pctSafe -gt 0) {
        $ctrl.LblStepPct.Text = "$pctSafe%"
    } else {
        $ctrl.LblStepPct.Text = ''
    }
    $parent = $ctrl.StepWaveContainer.Parent
    $maxW = if ($parent.ActualWidth -gt 0) { $parent.ActualWidth } else { 1200 }
    $ctrl.StepWaveContainer.Width = [Math]::Max(0, $maxW * $pctSafe / 100)
}

function Set-Phase {
    param([string]$Phase, [string]$Note)
    $ctrl.LblPhase.Text = $Phase
    if ($Note) { $ctrl.LblStats.Text = $Note }
}

# =============================================================
# Event handlers
# =============================================================
function Pick-Folder {
    param([string]$Initial)
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($Initial -and (Test-Path $Initial)) { $dlg.SelectedPath = $Initial }
    $dlg.Description = 'Choose folder'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    }
    return $null
}

$ctrl.BtnPickInput.add_Click({
    $p = Pick-Folder $ctrl.TxtInput.Text
    if ($p) { $ctrl.TxtInput.Text = $p; Update-PendingList }
})
$ctrl.BtnPickOutput.add_Click({
    $p = Pick-Folder $ctrl.TxtOutput.Text
    if ($p) { $ctrl.TxtOutput.Text = $p }
})

$ctrl.ChkOptimize.add_Checked({   $ctrl.ExpManual.IsExpanded = $false })
$ctrl.ChkOptimize.add_Unchecked({ $ctrl.ExpManual.IsExpanded = $true  })

$ctrl.ChkDelete.add_Checked({   $ctrl.ChkPermanent.IsEnabled = $true })
$ctrl.ChkDelete.add_Unchecked({
    $ctrl.ChkPermanent.IsEnabled = $false
    $ctrl.ChkPermanent.IsChecked = $false
})

$ctrl.ChkPermanent.add_Checked({
    $r = [System.Windows.MessageBox]::Show(
        "PERMANENT DELETE is ON.`n`nAfter a successful encode, the source file will be DELETED IMMEDIATELY - no backup, no recycle bin, no done\ folder.`n`nThis CANNOT be undone.`n`nAre you sure?",
        'Confirm permanent delete',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($r -ne 'Yes') { $ctrl.ChkPermanent.IsChecked = $false }
})

$ctrl.BtnRescan.add_Click({ Update-PendingList })

$ctrl.LstCompleted.add_SelectionChanged({
    $sel = $ctrl.LstCompleted.SelectedItem
    if ($sel) {
        $ctrl.DetEmpty.Visibility = 'Collapsed'
        $ctrl.DetContent.Visibility = 'Visible'
        $ctrl.DetName.Text    = $sel.Name
        $ctrl.DetCodec.Text   = $sel.Codec
        $ctrl.DetCrf.Text     = "$($sel.FoundCrf)"
        $ctrl.DetVmaf.Text    = if ($sel.FoundVmaf -gt 0) { ('{0:N2}' -f $sel.FoundVmaf) } else { '(no search)' }
        $ctrl.DetSizeIn.Text  = "$($sel.SizeIn) MB"
        $ctrl.DetSizeOut.Text = "$($sel.SizeOut) MB"
        $ctrl.DetRatio.Text   = "$($sel.Ratio)%"
        $ctrl.DetTime.Text    = "$($sel.ElapsedSec) sec"
        $ctrl.DetPath.Text    = $sel.OutputPath
    }
})

function Update-PendingList {
    $script:Pending.Clear()
    $dir = $ctrl.TxtInput.Text
    if (-not (Test-Path $dir)) { return }
    foreach ($f in (Get-InputFiles -InputDir $dir)) {
        $vm = [PSCustomObject]@{
            Name       = $f.Name
            FullPath   = $f.FullName
            Status     = 'Queued'
            StatusText = 'in queue'
            SizeMB     = [Math]::Round($f.Length / 1MB, 1)
        }
        $script:Pending.Add($vm)
    }
    Add-ConsoleLine "[INFO] $($script:Pending.Count) file(s) found in $dir"
}

# Laad opgeslagen settings (na alle function definitions)
Load-Settings
Update-PendingList

# Log flush timer
$logTimer = New-Object System.Windows.Threading.DispatcherTimer
$logTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$logTimer.add_Tick({
    $count = 0
    $line = $null
    while ($script:LogQueue.TryDequeue([ref]$line) -and $count -lt 50) {
        Add-ConsoleLine $line
        $count++
    }
})
$logTimer.Start()

# UI sync timer - leest SharedState en past toe op controls (UI thread only)
$uiSyncTimer = New-Object System.Windows.Threading.DispatcherTimer
$uiSyncTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$uiSyncTimer.add_Tick({
    # 1. Process file state actions (move pending->completed, status updates)
    $action = $null
    $processedCount = 0
    while ($script:UiActionQueue.TryDequeue([ref]$action) -and $processedCount -lt 20) {
        try {
            switch ($action.Type) {
                'StatusUpdate' {
                    $vm = $action.Vm
                    if ($vm) {
                        $vm.Status = $action.Status
                        $vm.StatusText = $action.StatusText
                        $i = $script:Pending.IndexOf($vm)
                        if ($i -ge 0) { $script:Pending[$i] = $vm }
                    }
                }
                'CompleteFile' {
                    $vm = $action.Vm
                    if ($vm) {
                        $script:Pending.Remove($vm) | Out-Null
                        $script:Completed.Add($action.CompletedVm)
                    }
                }
                'FailFile' {
                    $vm = $action.Vm
                    if ($vm) {
                        $vm.Status = 'Failed'
                        $vm.StatusText = $action.StatusText
                        $i = $script:Pending.IndexOf($vm)
                        if ($i -ge 0) { $script:Pending[$i] = $vm }
                    }
                }
            }
        } catch {}
        $processedCount++
    }

    # 2. Apply shared progress state
    if ($script:SharedState.Dirty) {
        $script:SharedState.Dirty = $false
        try {
            $ctrl.LblPhase.Text = $script:SharedState.PhaseLabel
            $ctrl.LblStats.Text = $script:SharedState.StatsText
            $ctrl.LblPct.Text = "$($script:SharedState.OverallPct)%"
            $parentW = $ctrl.WaveContainer.Parent
            $maxW = if ($parentW -and $parentW.ActualWidth -gt 0) { $parentW.ActualWidth } else { 1200 }
            $ctrl.WaveContainer.Width = [Math]::Max(0, $maxW * $script:SharedState.OverallPct / 100)

            $stepPct = $script:SharedState.StepPct
            $ctrl.LblStepName.Text = "Step: $($script:SharedState.StepName)"
            if ($stepPct -gt 0) { $ctrl.LblStepPct.Text = "$stepPct%" } else { $ctrl.LblStepPct.Text = '' }
            $stepParent = $ctrl.StepWaveContainer.Parent
            $sMaxW = if ($stepParent -and $stepParent.ActualWidth -gt 0) { $stepParent.ActualWidth } else { 1200 }
            $ctrl.StepWaveContainer.Width = [Math]::Max(0, $sMaxW * $stepPct / 100)
        } catch {}
    }

    # 3. Apply CPU/GPU bars (samples ge-updated door HwTimer)
    try {
        $cpuPct = [int]$script:HwUsage.Cpu
        $gpuPct = [int]$script:HwUsage.Gpu
        $ctrl.LblCpuVal.Text = "$cpuPct%"
        $ctrl.LblGpuVal.Text = "$gpuPct%"
        $cpuParent = $ctrl.CpuWaveContainer.Parent
        $cMaxW = if ($cpuParent -and $cpuParent.ActualWidth -gt 0) { $cpuParent.ActualWidth } else { 1200 }
        $ctrl.CpuWaveContainer.Width = [Math]::Max(0, $cMaxW * $cpuPct / 100)
        $gpuParent = $ctrl.GpuWaveContainer.Parent
        $gMaxW = if ($gpuParent -and $gpuParent.ActualWidth -gt 0) { $gpuParent.ActualWidth } else { 1200 }
        $ctrl.GpuWaveContainer.Width = [Math]::Max(0, $gMaxW * $gpuPct / 100)
    } catch {}
})
$uiSyncTimer.Start()

# =============================================================
# CPU + GPU sampling timer (1Hz, UI thread)
# Gebruikt PerformanceCounter (sneller dan Get-Counter cmdlet)
# =============================================================
$script:CpuCounter = $null
$script:GpuCounters = @()
try {
    $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor','% Processor Time','_Total')
    $script:CpuCounter.NextValue() | Out-Null   # eerste call returnt 0
} catch {
    $script:CpuCounter = $null
}
try {
    # GPU Engine counters per engine, we sommeren ze
    $cat = New-Object System.Diagnostics.PerformanceCounterCategory 'GPU Engine'
    $instances = $cat.GetInstanceNames()
    foreach ($inst in $instances) {
        try {
            $pc = New-Object System.Diagnostics.PerformanceCounter('GPU Engine','Utilization Percentage',$inst)
            $pc.NextValue() | Out-Null
            $script:GpuCounters += $pc
        } catch {}
    }
} catch {
    $script:GpuCounters = @()
}

$hwTimer = New-Object System.Windows.Threading.DispatcherTimer
$hwTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$hwTimer.add_Tick({
    try {
        if ($script:CpuCounter) {
            $cpu = [Math]::Round($script:CpuCounter.NextValue(), 0)
            $script:HwUsage.Cpu = [Math]::Max(0, [Math]::Min(100, $cpu))
        }
    } catch {}
    try {
        if ($script:GpuCounters.Count -gt 0) {
            # GPU usage = max van alle engines (sum kan >100% omdat meerdere engines parallel)
            $maxGpu = 0
            foreach ($pc in $script:GpuCounters) {
                try {
                    $v = $pc.NextValue()
                    if ($v -gt $maxGpu) { $maxGpu = $v }
                } catch {}
            }
            $script:HwUsage.Gpu = [Math]::Max(0, [Math]::Min(100, [int]$maxGpu))
        }
    } catch {}
})
$hwTimer.Start()

# =============================================================
# Worker via Runspace
# =============================================================
$script:WorkerPS = $null
$script:WorkerRS = $null
$script:WorkerAsync = $null
$script:Watcher = $null

function Stop-Worker {
    # Mark stop, kill child ffmpeg/dynamic-crf via Job Object (when window closes)
    # But we can also explicit-kill running child processes here.
    $script:StopRequested = $true
    $script:Paused = $false
    Get-Process | Where-Object { $_.Name -in @('ffmpeg','ffprobe','dynamic-crf','mediainfo') } 2>$null | ForEach-Object {
        try { $_.Kill() } catch {}
    }
    if ($script:WorkerPS) {
        try { $script:WorkerPS.Stop() } catch {}
    }
}

function Toggle-Pause {
    $script:Paused = -not $script:Paused
    if ($script:Paused) {
        $ctrl.BtnPause.Content = 'Resume'
        $script:LogQueue.Enqueue("[INFO] Pause requested - will halt after current file completes")
    } else {
        $ctrl.BtnPause.Content = 'Pause'
        $script:LogQueue.Enqueue("[INFO] Resumed")
    }
}

$ctrl.BtnPause.add_Click({ Toggle-Pause })
$ctrl.BtnStop.add_Click({
    $r = [System.Windows.MessageBox]::Show(
        "Stop all encoding right now? Current file will be killed mid-encode and lost.",
        'Confirm stop',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($r -eq 'Yes') {
        $script:LogQueue.Enqueue("[WARN] Stop requested by user - killing child processes")
        Stop-Worker
    }
})

function Start-EncodeAll {
    if ($script:Running) {
        [System.Windows.MessageBox]::Show('Encoding already in progress.', 'Busy', 'OK', 'Information') | Out-Null
        return
    }
    if ($script:Pending.Count -eq 0) {
        [System.Windows.MessageBox]::Show('No files in input folder.', 'Empty', 'OK', 'Information') | Out-Null
        return
    }

    $script:Running = $true
    $script:Paused = $false
    $script:StopRequested = $false

    $ctrl.BtnStart.IsEnabled = $false
    $ctrl.BtnStart.Content = 'RUNNING...'
    # Disable individual inputs (NIET de hele SetupPanel, anders zijn Pause/Stop ook dood)
    foreach ($c in @($ctrl.TxtInput, $ctrl.TxtOutput, $ctrl.BtnPickInput, $ctrl.BtnPickOutput,
                     $ctrl.CmbCodec, $ctrl.ChkOptimize, $ctrl.ChkDelete, $ctrl.ChkPermanent,
                     $ctrl.ExpManual, $ctrl.TxtCrf, $ctrl.TxtHeight, $ctrl.TxtVmaf, $ctrl.TxtTolerance,
                     $ctrl.BtnRescan)) {
        if ($c) { $c.IsEnabled = $false }
    }
    $ctrl.BtnPause.Visibility = 'Visible'
    $ctrl.BtnStop.Visibility  = 'Visible'
    $ctrl.BtnPause.IsEnabled = $true
    $ctrl.BtnStop.IsEnabled  = $true

    $codec    = $ctrl.CmbCodec.SelectedItem.Tag
    $optimize = $ctrl.ChkOptimize.IsChecked
    $deleteSrc= $ctrl.ChkDelete.IsChecked
    $permanent= $ctrl.ChkPermanent.IsChecked
    $manualCrf= [int]($ctrl.TxtCrf.Text)
    $heightVal= [int]($ctrl.TxtHeight.Text)
    $vmafVal  = [double]($ctrl.TxtVmaf.Text)
    $tolVal   = [double]($ctrl.TxtTolerance.Text)
    $outDir   = $ctrl.TxtOutput.Text

    $queue = @($script:Pending | ForEach-Object { $_ })
    $disp  = $window.Dispatcher

    $ps = [PowerShell]::Create()
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('queue', $queue)
    $rs.SessionStateProxy.SetVariable('codec', $codec)
    $rs.SessionStateProxy.SetVariable('optimize', $optimize)
    $rs.SessionStateProxy.SetVariable('deleteSrc', $deleteSrc)
    $rs.SessionStateProxy.SetVariable('permanent', $permanent)
    $rs.SessionStateProxy.SetVariable('manualCrf', $manualCrf)
    $rs.SessionStateProxy.SetVariable('heightVal', $heightVal)
    $rs.SessionStateProxy.SetVariable('vmafVal', $vmafVal)
    $rs.SessionStateProxy.SetVariable('tolVal', $tolVal)
    $rs.SessionStateProxy.SetVariable('outDir', $outDir)
    $rs.SessionStateProxy.SetVariable('rootDir', $Root)
    $rs.SessionStateProxy.SetVariable('logQ', $script:LogQueue)
    $rs.SessionStateProxy.SetVariable('disp', $disp)
    $rs.SessionStateProxy.SetVariable('pending', $script:Pending)
    $rs.SessionStateProxy.SetVariable('completed', $script:Completed)
    $rs.SessionStateProxy.SetVariable('uiCtrl', $ctrl)
    # Hashtable voor cross-thread flags
    $flags = @{
        Paused = $false
        Stop   = $false
    }
    $rs.SessionStateProxy.SetVariable('flags', $flags)
    $rs.SessionStateProxy.SetVariable('shared', $script:SharedState)
    $rs.SessionStateProxy.SetVariable('uiQ', $script:UiActionQueue)
    $script:WorkerFlags = $flags
    $ps.Runspace = $rs

    # Locate Encoder module - extern in gui\ OF inline (bundled exe)
    $encoderInline = ''
    $encoderExt = Join-Path $Root 'gui\Encoder.psm1'
    if (-not (Test-Path -LiteralPath $encoderExt)) {
        # Bundled mode: encoder code is al in dit script geladen.
        # Lees onze eigen functies en bundle voor de runspace.
        $fnsToShare = @('Get-AsaPaths','Get-CodecList','Test-EncoderAvailable','Get-AvailableEncoders',
                        'Get-VideoInfo','Invoke-FileEncode','Get-InputFiles','Remove-InputSource',
                        'New-CleanHardlink','ConvertFrom-FfmpegTime','Invoke-StreamingProcess',
                        'Add-ToJob','Stop-TrackedProcs')
        $sb = New-Object System.Text.StringBuilder
        foreach ($fn in $fnsToShare) {
            $cmd = Get-Command $fn -ErrorAction SilentlyContinue
            if ($cmd) {
                [void]$sb.AppendLine("function $fn {")
                [void]$sb.AppendLine($cmd.Definition)
                [void]$sb.AppendLine('}')
            }
        }
        $encoderInline = $sb.ToString()
    }
    $rs.SessionStateProxy.SetVariable('encoderInline', $encoderInline)
    $rs.SessionStateProxy.SetVariable('encoderExt', $encoderExt)

    [void]$ps.AddScript({
        if ($encoderInline) {
            Invoke-Expression $encoderInline
        } else {
            Import-Module $encoderExt -Force
        }

        # Worker schrijft ALLEEN naar shared state + queue.
        # UI thread leest dat via DispatcherTimer.
        # GEEN Dispatcher.Invoke vanuit worker - dat veroorzaakt thread-violations
        # met cross-runspace scriptblocks.

        $script:LastProgressMs = 0
        function Update-OverallBar($pct) {
            $now = [Environment]::TickCount
            if (($now - $script:LastProgressMs) -lt 100 -and $pct -lt 100) { return }
            $script:LastProgressMs = $now
            $shared.OverallPct = $pct
            $shared.Dirty = $true
        }
        $script:LastStepMs = 0
        function Update-StepBar($pct, $stepName) {
            $now = [Environment]::TickCount
            if (($now - $script:LastStepMs) -lt 100 -and $pct -lt 100 -and -not $stepName) { return }
            $script:LastStepMs = $now
            $shared.StepPct = $pct
            if ($stepName) { $shared.StepName = $stepName }
            $shared.Dirty = $true
        }
        function Set-Phase-Label($label, $stats) {
            $shared.PhaseLabel = $label
            $shared.StatsText  = $stats
            $shared.Dirty = $true
        }

        for ($idx = 0; $idx -lt $queue.Count; $idx++) {
            if ($flags.Stop) {
                $logQ.Enqueue("[WARN] Stopped by user, $($queue.Count - $idx) file(s) skipped")
                break
            }
            while ($flags.Paused -and -not $flags.Stop) {
                Start-Sleep -Milliseconds 500
            }
            if ($flags.Stop) { break }

            $vm = $queue[$idx]
            $logQ.Enqueue("[INFO] ============================================================")
            $logQ.Enqueue("[INFO] Start ($($idx+1)/$($queue.Count)): $($vm.Name)")

            # Status update via queue
            $uiQ.Enqueue(@{
                Type = 'StatusUpdate'
                Vm = $vm
                Status = 'Probing'
                StatusText = 'starting...'
            })
            Set-Phase-Label "[$($idx+1)/$($queue.Count)] $($vm.Name)" ''
            Update-OverallBar 0
            Update-StepBar 0 'preparing'

            $vmRef = $vm  # closure capture
            $lineCb = {
                param($t)
                $logQ.Enqueue($t)
            }.GetNewClosure()

            $statusCb = {
                param($phase, $pct, $note)
                $uiQ.Enqueue(@{
                    Type = 'StatusUpdate'
                    Vm = $vmRef
                    Status = $phase
                    StatusText = "$phase  $note"
                })
                Set-Phase-Label $shared.PhaseLabel $note
                Update-StepBar $pct $phase
            }.GetNewClosure()

            $progCb = {
                param($pct, $speed, $eta)
                Update-OverallBar $pct
            }.GetNewClosure()

            $r = Invoke-FileEncode `
                -InputFile $vm.FullPath `
                -OutputDir $outDir `
                -Codec $codec `
                -Optimize $optimize `
                -ManualCrf $manualCrf `
                -Height $heightVal `
                -TargetVmaf $vmafVal `
                -Tolerance $tolVal `
                -BaseDir $rootDir `
                -LineCallback $lineCb `
                -StatusCallback $statusCb `
                -ProgressCallback $progCb

            if ($r.Success) {
                $compVm = [PSCustomObject]@{
                    Name       = $vm.Name
                    OutputPath = $r.OutputPath
                    SizeIn     = $r.SizeIn
                    SizeOut    = $r.SizeOut
                    Ratio      = $r.Ratio
                    Codec      = $r.Codec
                    FoundCrf   = $r.FoundCrf
                    FoundVmaf  = $r.FoundVmaf
                    ElapsedSec = $r.ElapsedSec
                }
                $uiQ.Enqueue(@{
                    Type = 'CompleteFile'
                    Vm = $vm
                    CompletedVm = $compVm
                })
                if ($deleteSrc) {
                    Remove-InputSource -InputFile $vm.FullPath -Permanent $permanent
                    $logQ.Enqueue("[INFO] source disposed: permanent=$permanent")
                }
                Update-OverallBar 100
                Update-StepBar 100 'completed'
            } else {
                $uiQ.Enqueue(@{
                    Type = 'FailFile'
                    Vm = $vm
                    StatusText = "FAIL: $($r.Error)"
                })
                $logQ.Enqueue("[ERR] Encoding failed: $($r.Error)")
            }
        }

        Set-Phase-Label 'Idle' "done"
        Update-StepBar 0 '(idle)'
        $logQ.Enqueue("[OK] ============================================================")
        $logQ.Enqueue("[OK] All tasks finished.")
    })

    $script:WorkerPS = $ps
    $script:WorkerRS = $rs
    $script:WorkerAsync = $ps.BeginInvoke()

    # Watcher
    $watcher = New-Object System.Windows.Threading.DispatcherTimer
    $watcher.Interval = [TimeSpan]::FromMilliseconds(400)
    $watcher.add_Tick({
        # Sync flags from script-scope to worker hashtable
        if ($script:WorkerFlags) {
            $script:WorkerFlags.Paused = $script:Paused
            $script:WorkerFlags.Stop = $script:StopRequested
        }
        if ($script:WorkerAsync.IsCompleted) {
            $watcher.Stop()
            try { [void]$script:WorkerPS.EndInvoke($script:WorkerAsync) } catch {
                $script:LogQueue.Enqueue("[ERR] worker exception: $($_.Exception.Message)")
            }
            $script:WorkerPS.Dispose()
            $script:WorkerRS.Close()
            $script:WorkerPS = $null
            $script:WorkerRS = $null
            $script:WorkerAsync = $null
            $script:Running = $false
            $script:Paused = $false
            $script:StopRequested = $false
            $ctrl.BtnStart.IsEnabled = $true
            $ctrl.BtnStart.Content = 'START'
            # Re-enable individual inputs
            foreach ($c in @($ctrl.TxtInput, $ctrl.TxtOutput, $ctrl.BtnPickInput, $ctrl.BtnPickOutput,
                             $ctrl.CmbCodec, $ctrl.ChkOptimize, $ctrl.ChkDelete, $ctrl.ChkPermanent,
                             $ctrl.ExpManual, $ctrl.TxtCrf, $ctrl.TxtHeight, $ctrl.TxtVmaf, $ctrl.TxtTolerance,
                             $ctrl.BtnRescan)) {
                if ($c) { $c.IsEnabled = $true }
            }
            $ctrl.ChkPermanent.IsEnabled = ($ctrl.ChkDelete.IsChecked -eq $true)
            $ctrl.BtnPause.Visibility = 'Collapsed'
            $ctrl.BtnStop.Visibility  = 'Collapsed'
            $ctrl.BtnPause.Content = 'Pause'
        }
    })
    $script:Watcher = $watcher
    $watcher.Start()
}

$ctrl.BtnStart.add_Click({ Save-Settings; Start-EncodeAll })

# =============================================================
# Install / Reinstall - schrijft install-dynamic-crf.bat naar disk
# (uit embedded base64 als bundled exe, of pakt het lokaal) + runt het
# =============================================================
function Get-InstallBatPath {
    $localBat = Join-Path $Root 'install-dynamic-crf.bat'
    if (Test-Path -LiteralPath $localBat) { return $localBat }
    # Bundled: schrijf naast gm-encoder.exe (zodat %~dp0 binnen de bat naar $Root resolved
    # en bin\ffmpeg etc. in $Root\bin\ terecht komen, niet in %TEMP%\bin)
    if ($script:InstallBatBase64) {
        $extracted = Join-Path $Root 'install-dynamic-crf.bat'
        try {
            $bytes = [Convert]::FromBase64String($script:InstallBatBase64)
            [System.IO.File]::WriteAllBytes($extracted, $bytes)
            return $extracted
        } catch {}
    }
    return $null
}

function Invoke-Installer {
    param([bool]$Force = $false)
    if ($script:Running) {
        [System.Windows.MessageBox]::Show('Encoding bezig - wacht tot klaar of stop eerst.', 'Bezig', 'OK', 'Information') | Out-Null
        return
    }
    $bat = Get-InstallBatPath
    if (-not $bat) {
        [System.Windows.MessageBox]::Show('install-dynamic-crf.bat niet gevonden en niet embedded.', 'Missing', 'OK', 'Error') | Out-Null
        return
    }
    if ($Force) {
        # Reinstall: verwijder dynamic-crf.exe eerst zodat installer rebuild
        $dcrf = Join-Path $Root 'dynamic-crf.exe'
        if (Test-Path -LiteralPath $dcrf) {
            try { Remove-Item -LiteralPath $dcrf -Force -ErrorAction Stop }
            catch {
                [System.Windows.MessageBox]::Show("Kon dynamic-crf.exe niet verwijderen: $($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
                return
            }
        }
    }

    # Disable knoppen
    $ctrl.BtnInstall.IsEnabled = $false
    $ctrl.BtnReinstall.IsEnabled = $false
    $ctrl.BtnStart.IsEnabled = $false

    Add-ConsoleLine "[INFO] ============================================================"
    Add-ConsoleLine "[INFO] Installer gestart: $bat"

    # Run installer in achtergrond, streamt output naar console
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/c `"`"$bat`" 2>&1`""
    $psi.WorkingDirectory = $Root
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true   # zodat Read-Host in de bat direct EOF krijgt
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $lines = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]@())
    $act = { if ($EventArgs.Data) { [void]$Event.MessageData.Add($EventArgs.Data) } }
    $e1 = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $act -MessageData $lines
    $e2 = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $act -MessageData $lines
    [void]$proc.Start()
    if (Get-Command Add-ToJob -ErrorAction SilentlyContinue) { Add-ToJob $proc }
    # Sluit stdin direct zodat Read-Host in de bat geen blocking wait krijgt
    try { $proc.StandardInput.Close() } catch {}
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    # Stream lines via DispatcherTimer
    $installTimer = New-Object System.Windows.Threading.DispatcherTimer
    $installTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $installTimer.add_Tick({
        while ($lines.Count -gt 0) {
            $line = $lines[0]
            $lines.RemoveAt(0)
            if ($line) { $script:LogQueue.Enqueue($line) }
        }
        if ($proc.HasExited -and $lines.Count -eq 0) {
            $installTimer.Stop()
            try { Unregister-Event -SourceIdentifier $e1.Name -ErrorAction SilentlyContinue } catch {}
            try { Unregister-Event -SourceIdentifier $e2.Name -ErrorAction SilentlyContinue } catch {}
            try { $script:LogQueue.Enqueue("[OK] Installer klaar (exit $($proc.ExitCode))") } catch {}
            try { $script:LogQueue.Enqueue("[INFO] Codec lijst opnieuw scannen...") } catch {}
            # Refresh codec status (gefaalde refresh mag knoppen niet blokkeren)
            try {
                $ffmpegPath = Join-Path $Root 'bin\ffmpeg\bin\ffmpeg.exe'
                if (Test-Path -LiteralPath $ffmpegPath) {
                    $newEnc = Get-AvailableEncoders -FfmpegPath $ffmpegPath
                    for ($i = 0; $i -lt $ctrl.CmbCodec.Items.Count; $i++) {
                        $item = $ctrl.CmbCodec.Items[$i]
                        $codec = $item.Tag
                        $ok = if ($newEnc[$codec]) { '[OK]' } else { '[--]' }
                        $info = (Get-CodecList)[$i]
                        $item.Content = "$ok  $($info.Display)  ($codec)"
                    }
                }
            } catch {
                try { $script:LogQueue.Enqueue("[WARN] codec refresh skipped: $($_.Exception.Message)") } catch {}
            }
            # Buttons ALTIJD terug enabled, ongeacht refresh-resultaat
            $ctrl.BtnInstall.IsEnabled = $true
            $ctrl.BtnReinstall.IsEnabled = $true
            $ctrl.BtnStart.IsEnabled = $true
        }
    })
    $installTimer.Start()
}

$ctrl.BtnInstall.add_Click({ Invoke-Installer -Force $false })
$ctrl.BtnReinstall.add_Click({
    $r = [System.Windows.MessageBox]::Show(
        "Reinstall verwijdert dynamic-crf.exe en bouwt opnieuw met laatste patches.`nDoorgaan?",
        'Confirm reinstall', 'YesNo', 'Question')
    if ($r -eq 'Yes') { Invoke-Installer -Force $true }
})

$window.add_Closing({
    if ($script:Running) {
        $r = [System.Windows.MessageBox]::Show(
            'Encoding is still running. Close anyway? (ffmpeg/dynamic-crf will be killed)',
            'Busy',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($r -ne 'Yes') {
            $_.Cancel = $true
            return
        }
        Stop-Worker
    }
    Save-Settings
    if ($logTimer)    { $logTimer.Stop() }
    if ($uiSyncTimer) { $uiSyncTimer.Stop() }
    if ($hwTimer)     { $hwTimer.Stop() }
})

Add-ConsoleLine "[INFO] GM Encoder ready. Pick input/output folders, select codec, click START."

$window.ShowDialog() | Out-Null
