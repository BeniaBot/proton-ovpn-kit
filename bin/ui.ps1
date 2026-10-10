# The kit's look: WPF windows (built into every Windows 10/11, nothing to install),
# rounded, with a shadow, light or dark like the Windows setting, sharp at any display
# scaling. If WPF cannot load - or Windows is in high-contrast mode, where our own colors
# would fight the user's - everything falls back to the plain WinForms windows.
# Dot-sourced by common.ps1.

$script:UiMode = $null      # 'wpf' or 'classic', decided on first use

function Test-Wpf {
    if ($script:UiMode) { return $script:UiMode -eq 'wpf' }
    $script:UiMode = 'classic'
    if ($env:PROTON_KIT_CLASSIC) { return $false }                    # for testing the fallback
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { return $false }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        if ([Windows.SystemParameters]::HighContrast) { return $false }
        $script:UiMode = 'wpf'
    } catch { }
    $script:UiMode -eq 'wpf'
}

function Get-UiTheme {
    $light = $true
    try {
        $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme -ErrorAction Stop
        $light = $v -ne 0
    } catch { }
    if ($env:PROTON_KIT_THEME) { $light = $env:PROTON_KIT_THEME -ne 'dark' }   # for testing
    if ($light) {
        @{ Bg = '#FFFFFF'; Surface = '#F3F4F6'; SurfaceHover = '#E9EBEF'; Line = '#E2E5EA'; Text = '#1B1D22'; Sub = '#646B76'
           Accent = '#6D4AFF'; AccentHover = '#5A38EE'; AccentSoft = '#EFEBFF'; OnAccent = '#FFFFFF'
           Green = '#18884A'; GreenSoft = '#E5F5EB'; Amber = '#B26F00'; AmberSoft = '#FFF3DC'; Red = '#CC2A36'; RedSoft = '#FCEBEC'
           Shadow = '0.22'; FlagEdge = '#26000000' }
    } else {
        @{ Bg = '#1E1F24'; Surface = '#2A2C33'; SurfaceHover = '#343740'; Line = '#3A3D46'; Text = '#ECEEF2'; Sub = '#A2A8B2'
           Accent = '#8F78FF'; AccentHover = '#A592FF'; AccentSoft = '#2F2950'; OnAccent = '#FFFFFF'
           Green = '#45C27A'; GreenSoft = '#1B3426'; Amber = '#E9A93F'; AmberSoft = '#3B2F17'; Red = '#F2646B'; RedSoft = '#40222A'
           Shadow = '0.55'; FlagEdge = '#33FFFFFF' }
    }
}

# Inside right-to-left Hebrew text, a file name like 2-connect.cmd is shown scrambled
# ("connect.cmd-2"). A left-to-right mark (LRM) on each side keeps it whole. Tested:
# WPF ignores the embedding marks (LRE/PDF, LRI/PDI) but honors LRM.
function Protect-LatinNames([string]$s) {
    [regex]::Replace($s, '[0-9A-Za-z][0-9A-Za-z\-_.]*\.(cmd|log|txt|dat)\b', { param($m) [char]0x200E + $m.Value + [char]0x200E })
}

function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

function Get-Brush([string]$Hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }

# The window frame shared by every window; $Body is the XAML of what goes inside.
function New-UiWindow([string]$Body, [string]$Title = 'Proton VPN', [switch]$Minimize, [switch]$Persistent) {
    $t = Get-UiTheme
    $minButton = if ($Minimize) { '<Button x:Name="MinBtn" Style="{StaticResource Chrome}" Content="&#xE921;" ToolTip="מזעור"/>' } else { '' }
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize"
        SizeToContent="WidthAndHeight" WindowStartupLocation="CenterScreen" FlowDirection="RightToLeft"
        FontFamily="Segoe UI" FontSize="14" Foreground="{{Text}}" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" ShowInTaskbar="True" Topmost="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Background" Value="{{Surface}}"/>
      <Setter Property="BorderBrush" Value="{{Line}}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="20,9"/>
      <Setter Property="MinWidth" Value="104"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{{Accent}}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{{SurfaceHover}}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{{Accent}}"/>
      <Setter Property="BorderBrush" Value="{{Accent}}"/>
      <Setter Property="Foreground" Value="{{OnAccent}}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{{AccentHover}}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{{RedSoft}}"/>
      <Setter Property="BorderBrush" Value="{{RedSoft}}"/>
      <Setter Property="Foreground" Value="{{Red}}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{{Red}}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Foreground" Value="{{Sub}}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{{SurfaceHover}}"/><Setter Property="Foreground" Value="{{Text}}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Close" TargetType="Button" BasedOn="{StaticResource Chrome}">
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{{Red}}"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Card" TargetType="Button">
      <Setter Property="Background" Value="{{Surface}}"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="2"
                    CornerRadius="12" Padding="14,11">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{{SurfaceHover}}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{{Line}}"/></Trigger>
        <Trigger Property="Tag" Value="current"><Setter Property="Background" Value="{{AccentSoft}}"/><Setter Property="BorderBrush" Value="{{Accent}}"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <Border Margin="20" CornerRadius="14" Background="{{Bg}}" BorderBrush="{{Line}}" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Direction="270" Opacity="{{Shadow}}"/></Border.Effect>
    <DockPanel>
      <Grid x:Name="TitleBar" DockPanel.Dock="Top" Height="44" Background="Transparent">
        <TextBlock x:Name="TitleText" Margin="20,0,0,0" VerticalAlignment="Center" FontSize="12" Foreground="{{Sub}}"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,6,0">
          {{MIN}}
          <Button x:Name="CloseBtn" Style="{StaticResource Close}" Content="&#xE8BB;" ToolTip="סגירה"/>
        </StackPanel>
      </Grid>
      <Border Padding="26,2,26,24">
{{BODY}}
      </Border>
    </DockPanel>
  </Border>
</Window>
'@
    foreach ($k in $t.Keys) { $xaml = $xaml.Replace("{{$k}}", $t[$k]) }
    $xaml = $xaml.Replace('{{MIN}}', $minButton).Replace('{{BODY}}', $Body)
    foreach ($k in $t.Keys) { $xaml = $xaml.Replace("{{$k}}", $t[$k]) }   # the body uses the same color names
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $w.FindName('TitleText').Text = $Title
    $w.Title = $Title
    $w.Icon = New-AppIcon
    $w.FindName('TitleBar').Add_MouseLeftButtonDown({ try { [Windows.Window]::GetWindow($this).DragMove() } catch { } })
    $w.FindName('CloseBtn').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    if ($Minimize) { $w.FindName('MinBtn').Add_Click({ [Windows.Window]::GetWindow($this).WindowState = 'Minimized' }) }
    # Shown hidden behind other windows is the classic "it's stuck" moment; come to front.
    $w.Add_ContentRendered({ $this.Activate() | Out-Null })
    if ($env:PROTON_KIT_TEST_CLOSE -and -not $Persistent) {   # automated tests: dialogs close by themselves
        $tt = New-Object Windows.Threading.DispatcherTimer; $tt.Interval = [TimeSpan]::FromSeconds([int]$env:PROTON_KIT_TEST_CLOSE); $tt.Tag = $w
        $tt.Add_Tick({ $this.Stop(); if ($env:PROTON_KIT_TEST_ANSWER) { $script:MsgResult = $env:PROTON_KIT_TEST_ANSWER }; $this.Tag.Close() }); $tt.Start()
    }
    $w
}

# Taskbar icon: a rounded tile in the accent color with a lock - or, given a country,
# that country's flag, so the taskbar itself shows where you are connected.
function New-AppIcon([string]$Code) {
    try {
        $t = Get-UiTheme
        $dv = New-Object Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $flag = if ($Code) { Get-FlagSource $Code } else { $null }
        if ($flag) {
            $brush = New-Object Windows.Media.ImageBrush($flag); $brush.Stretch = 'UniformToFill'
            $dc.DrawRoundedRectangle($brush, $null, (New-Object Windows.Rect(0, 10, 64, 44)), 8, 8)
        } else {
            $dc.DrawRoundedRectangle((Get-Brush '#6D4AFF'), $null, (New-Object Windows.Rect(0, 0, 64, 64)), 16, 16)
            $ft = New-Object Windows.Media.FormattedText([string][char]0xE72E, [Globalization.CultureInfo]::InvariantCulture, 'LeftToRight',
                (New-Object Windows.Media.Typeface('Segoe MDL2 Assets')), 34, (Get-Brush '#FFFFFF'))
            $dc.DrawText($ft, (New-Object Windows.Point((64 - $ft.Width) / 2, (64 - $ft.Height) / 2)))
        }
        $dc.Close()
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32))
        $bmp.Render($dv); $bmp.Freeze(); $bmp
    } catch { $null }
}

function Get-FlagPath([string]$Code) { Join-Path $Bin ('flags\' + $Code.ToLower() + '.png') }

function Get-FlagSource([string]$Code) {
    $p = Get-FlagPath $Code
    if (-not (Test-Path $p)) { return $null }
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.UriSource = New-Object Uri($p); $bi.CacheOption = 'OnLoad'; $bi.EndInit(); $bi.Freeze()
    $bi
}

# XAML for a rounded flag. FlowDirection LeftToRight: under RTL, WPF would mirror the image.
function Get-FlagXaml([string]$Code, [int]$W, [int]$H, [int]$Radius, [string]$Name = '') {
    $nameAttr = if ($Name) { "x:Name=""$Name""" } else { '' }
    $p = Get-FlagPath $Code
    $fill = if (Test-Path $p) { '<ImageBrush Stretch="UniformToFill" ImageSource="' + (ConvertTo-XmlText $p) + '"/>' } else { '<SolidColorBrush Color="{{Surface}}"/>' }
    "<Border $nameAttr Width=""$W"" Height=""$H"" CornerRadius=""$Radius"" FlowDirection=""LeftToRight"" BorderBrush=""{{FlagEdge}}"" BorderThickness=""1""><Border.Background>$fill</Border.Background></Border>"
}

# The modern message box. Same contract as the classic Show-Msg.
function Show-UiDialog([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK', [int]$AutoCloseSec = 0) {
    $look = @{ Information = @('i', 'Accent', 'AccentSoft'); Question = @('?', 'Accent', 'AccentSoft'); Success = @([string][char]0x2713, 'Green', 'GreenSoft')
               Warning = @('!', 'Amber', 'AmberSoft'); Error = @([string][char]0x2715, 'Red', 'RedSoft') }[$Icon]
    if (-not $look) { $look = @('i', 'Accent', 'AccentSoft') }
    $body = @"
<StackPanel MinWidth="340" MaxWidth="470">
  <DockPanel>
    <Border DockPanel.Dock="Left" Width="42" Height="42" CornerRadius="21" Background="{{$($look[2])}}" VerticalAlignment="Top" Margin="0,0,16,0">
      <TextBlock Text="$(ConvertTo-XmlText $look[0])" FontSize="21" FontWeight="Bold" Foreground="{{$($look[1])}}" HorizontalAlignment="Center" VerticalAlignment="Center" FlowDirection="LeftToRight"/>
    </Border>
    <TextBlock x:Name="Msg" TextWrapping="Wrap" FontSize="15" LineHeight="23" VerticalAlignment="Center" Margin="0,8,0,0"/>
  </DockPanel>
  <StackPanel x:Name="Buttons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"/>
</StackPanel>
"@
    $w = New-UiWindow $body
    $w.FindName('Msg').Text = $Text
    $defs = @{ OK = ,@('אישור', 'OK'); OKCancel = @(@('אישור', 'OK'), @('ביטול', 'Cancel')); YesNo = @(@('כן', 'Yes'), @('לא', 'No')) }[$Buttons]
    $script:MsgResult = @{ OK = 'OK'; OKCancel = 'Cancel'; YesNo = 'No' }[$Buttons]   # closing with X
    # Declared here on purpose: PowerShell looks up an unset name in the caller's scope, and
    # the status window's own $timer was found and stopped - the connection went unwatched.
    $timer = $null
    $first = $true
    foreach ($d in $defs) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $d[0]; $b.Tag = $d[1]; $b.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
        $b.Style = $w.FindResource($(if ($first) { 'Primary' } else { 'Btn' }))
        if ($first) { $b.IsDefault = $true } else { $b.IsCancel = $true }
        $b.Add_Click({ $script:MsgResult = $this.Tag; [Windows.Window]::GetWindow($this).Close() })
        [void]$w.FindName('Buttons').Children.Add($b)
        $first = $false
    }
    if ($AutoCloseSec -gt 0) {
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds($AutoCloseSec); $timer.Tag = $w
        $timer.Add_Tick({ $this.Stop(); $this.Tag.Close() })
        $timer.Start()
    }
    $w.Add_ContentRendered({ $this.FindName('Buttons').Children[0].Focus() | Out-Null })
    [void]$w.ShowDialog()
    if ($timer) { $timer.Stop() }
    $script:MsgResult
}

function Show-Msg([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK', [int]$AutoCloseSec = 0) {
    Write-Host "[message $Icon] $($Text -replace "`n+", ' / ')"   # lands in connect-last.log: what the user was told
    $Text = Protect-LatinNames $Text
    if (Test-Wpf) {
        try { return Show-UiDialog $Text $Icon $Buttons $AutoCloseSec } catch { $script:UiMode = 'classic' }
    }
    if ($Icon -eq 'Success') { $Icon = 'Information' }
    Show-MsgClassic $Text $Icon $Buttons $AutoCloseSec
}

# Country picker. Returns the picked code, or $null.
# $Current: the highlighted country; $Status: the line under the title.
function Show-CountryPicker($Countries, [string]$Current, [string]$Status) {
    if (Test-Wpf) {
        try { return Show-CountryPickerWpf $Countries $Current $Status } catch { $script:UiMode = 'classic' }
    }
    Show-CountryPickerClassic $Countries $Current $Status
}

function Show-CountryPickerWpf($Countries, [string]$Current, [string]$Status) {
    $sections = foreach ($near in $true, $false) {
        $title = if ($near) { 'קרוב ומהיר' } else { 'רחוק, איטי יותר' }
        $cards = foreach ($c in $Countries | Where-Object { $_.Near -eq $near }) {
            $tag = if ($c.Code -eq $Current) { 'current' } else { '' }
            $check = if ($tag) { '<Border DockPanel.Dock="Right" Width="22" Height="22" CornerRadius="11" Background="{{Accent}}" VerticalAlignment="Center"><TextBlock Text="&#x2713;" Foreground="{{OnAccent}}" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>' } else { '' }
            @"
<Button x:Name="c_$($c.Code)" Style="{StaticResource Card}" Tag="$tag" Width="208" Margin="0,0,10,10">
  <DockPanel>
    <Border DockPanel.Dock="Left" Margin="0,0,12,0">$(Get-FlagXaml $c.Code 42 28 5)</Border>
    $check
    <TextBlock Text="$(ConvertTo-XmlText $c.Name)" FontSize="15" FontWeight="$(if ($tag) { 'SemiBold' } else { 'Normal' })" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
  </DockPanel>
</Button>
"@
        }
        @"
<TextBlock Text="$title" FontSize="12.5" FontWeight="SemiBold" Foreground="{{Sub}}" Margin="2,18,0,10"/>
<WrapPanel Width="654">$($cards -join "`n")</WrapPanel>
"@
    }
    $body = @"
<StackPanel>
  <TextBlock Text="לאן להתחבר?" FontSize="24" FontWeight="SemiBold" Margin="2,0,0,0"/>
  <TextBlock x:Name="Status" FontSize="13.5" Foreground="{{Sub}}" Margin="2,4,0,0"/>
  <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
    <StackPanel>$($sections -join "`n")</StackPanel>
  </ScrollViewer>
  <DockPanel Margin="2,12,0,0">
    <Button x:Name="Cancel" DockPanel.Dock="Left" Style="{StaticResource Btn}" Content="סגירה" IsCancel="True"/>
    <TextBlock Text="הבחירה נשמרת גם לחיבורים הבאים." FontSize="12.5" Foreground="{{Sub}}" VerticalAlignment="Center" HorizontalAlignment="Right"/>
  </DockPanel>
</StackPanel>
"@
    $w = New-UiWindow $body
    $w.FindName('Status').Text = $Status
    # small screens, or big display scaling: never taller than the screen
    $w.FindName('Scroll').MaxHeight = [Math]::Max(220, [Windows.SystemParameters]::WorkArea.Height - 260)
    $script:PickedCode = $null
    foreach ($c in $Countries) {
        $b = $w.FindName("c_$($c.Code)")
        if ($b) { $b.Add_Click({ $script:PickedCode = $this.Name.Substring(2); [Windows.Window]::GetWindow($this).Close() }) }
    }
    $w.FindName('Cancel').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    $w.Add_ContentRendered({ $b = $this.FindName("c_$Current"); if ($b) { $b.Focus() | Out-Null } }.GetNewClosure())
    [void]$w.ShowDialog()
    $script:PickedCode
}

# The plain version (WinForms), for when WPF is not available.
function Show-CountryPickerClassic($Countries, [string]$Current, [string]$Status) {
    $blue = [Drawing.Color]::FromArgb(47, 111, 235); $gray = [Drawing.Color]::FromArgb(96, 103, 112); $line = [Drawing.Color]::FromArgb(200, 205, 212)
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Proton VPN'; $form.StartPosition = 'CenterScreen'; $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true; $form.BackColor = [Drawing.Color]::White
    $form.Font = New-Object Drawing.Font('Segoe UI', 11)
    $form.AutoSize = $true; $form.AutoSizeMode = 'GrowAndShrink'; $form.Padding = New-Object Windows.Forms.Padding(18, 14, 18, 14)
    $stack = New-Object Windows.Forms.FlowLayoutPanel -Property @{ FlowDirection = 'TopDown'; AutoSize = $true; WrapContents = $false }
    $addLabel = { param($Text, $Size, $Style, $Color, $Top)
        $stack.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = $Text; AutoSize = $true; ForeColor = $Color
            Font = (New-Object Drawing.Font('Segoe UI', $Size, [Drawing.FontStyle]$Style)); Margin = (New-Object Windows.Forms.Padding(2, $Top, 2, 4)) })) }
    & $addLabel 'לאן להתחבר?' 15 'Bold' ([Drawing.Color]::FromArgb(32, 33, 36)) 0
    & $addLabel $Status 10.5 'Regular' $gray 0
    $script:PickedCode = $null
    foreach ($near in $true, $false) {
        & $addLabel $(if ($near) { 'קרוב ומהיר' } else { 'רחוק, איטי יותר' }) 10.5 'Bold' $gray 14
        $grid = New-Object Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; WrapContents = $true
            MaximumSize = (New-Object Drawing.Size(666, 0)); Margin = (New-Object Windows.Forms.Padding(0)) }
        foreach ($c in $Countries | Where-Object { $_.Near -eq $near }) {
            $isCurrent = $c.Code -eq $Current
            $img = $null
            if (Test-Path (Get-FlagPath $c.Code)) {   # flag on a canvas with a gap before the name
                $src = [Drawing.Image]::FromFile((Get-FlagPath $c.Code)); $img = New-Object Drawing.Bitmap(52, 30)
                $g = [Drawing.Graphics]::FromImage($img); $g.InterpolationMode = 'HighQualityBicubic'
                $g.DrawImage($src, 10, 2, 40, 26); $g.DrawRectangle((New-Object Drawing.Pen([Drawing.Color]::FromArgb(70, 0, 0, 0))), 10, 2, 39, 25)
                $g.Dispose(); $src.Dispose()
            }
            $b = New-Object Windows.Forms.Button -Property @{ Text = $c.Name; Tag = $c.Code; Image = $img
                TextImageRelation = 'ImageBeforeText'; ImageAlign = 'MiddleLeft'; TextAlign = 'MiddleLeft'
                Size = (New-Object Drawing.Size(214, 52)); Margin = (New-Object Windows.Forms.Padding(4)); FlatStyle = 'Flat'; Cursor = 'Hand'
                BackColor = $(if ($isCurrent) { [Drawing.Color]::FromArgb(234, 241, 254) } else { [Drawing.Color]::White }) }
            $b.FlatAppearance.BorderColor = $(if ($isCurrent) { $blue } else { $line }); $b.FlatAppearance.BorderSize = $(if ($isCurrent) { 2 } else { 1 })
            if ($isCurrent) { $b.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold) }
            $b.Add_Click({ $script:PickedCode = $this.Tag; $this.FindForm().Close() })
            $grid.Controls.Add($b)
        }
        $stack.Controls.Add($grid)
    }
    $close = New-Object Windows.Forms.Button -Property @{ Text = 'סגירה'; AutoSize = $true; MinimumSize = (New-Object Drawing.Size(96, 34)); Margin = (New-Object Windows.Forms.Padding(2, 12, 2, 0)) }
    $close.Add_Click({ $this.FindForm().Close() })
    $stack.Controls.Add($close); $form.CancelButton = $close
    $form.Controls.Add($stack)
    [void]$form.ShowDialog(); $form.Dispose()
    $script:PickedCode
}
