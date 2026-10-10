using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Drawing;
using System.Xml;
using System.Security.AccessControl;
using System.Security.Principal;
[assembly: AssemblyTitle("特好装 Codex 测试安装程序")]
[assembly: AssemblyVersion("4.6.0.0")]
public static partial class Bootstrap {
 static string stage="UNEXPECTED", errorCode="UNEXPECTED_FAILED", logPath;
 static readonly bool CiTest = string.Equals(Environment.GetEnvironmentVariable("THZ_CI_TEST"), "1", StringComparison.Ordinal);
 static int? lastExit;
 // 真实 BuildNumber：Environment.OSVersion.Version 在无 Win10+ manifest 时被垫片固定为 6.2.9200；读注册表 CurrentBuildNumber（与预检 CIM 口径一致），失败回退
 static readonly string RealOsBuild = GetRealOsBuild();
 static string GetRealOsBuild(){
  try{
   var key=Microsoft.Win32.Registry.LocalMachine.OpenSubKey("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
   if(key!=null){var v=key.GetValue("CurrentBuildNumber") as string;key.Close();if(!string.IsNullOrEmpty(v))return v;}
  }catch{}
  return Environment.OSVersion.Version.ToString();
 }
 static void InitLog(){
  string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"THZ","InstallerLogs");
  Directory.CreateDirectory(root);logPath=Path.Combine(root,"beta-"+Guid.NewGuid().ToString("N")+".log");
  if(CiTest)Console.WriteLine("THZ_CI_DIAGLOG="+logPath);
  Log("START",null);
 }
 static void Log(string result,Exception error){
  if(result=="PASS")errorCode="NONE";
  try{File.AppendAllText(logPath,DateTime.UtcNow.ToString("o")+" installer=4.6.0.0 windows="+RealOsBuild+" stage="+stage+" code="+(result=="PENDING"?"NONE":errorCode)+" exit="+(lastExit.HasValue?lastExit.Value.ToString():"NONE")+" exception="+(error==null?"NONE":error.GetType().FullName)+" workspace="+(workspace??"NONE")+" verification="+result+Environment.NewLine);}catch{}
 }
 static void LogDetail(string code,string candidate,Exception error){
  try{
   string msg=error==null?"NONE":(error.GetType().FullName+": "+(error.Message??"")).Replace("\r"," ").Replace("\n"," ");
   if(msg.Length>600)msg=msg.Substring(0,600);
   string cand=(candidate??"NONE").Replace("\r"," ").Replace("\n"," ");
   File.AppendAllText(logPath,DateTime.UtcNow.ToString("o")+" installer=4.6.0.0 windows="+RealOsBuild+" stage=EXTRACT code="+code+" candidate="+cand+" exception_detail="+msg+Environment.NewLine);
  }catch{}
 }
 static void Stage(string value,string code){stage=value;errorCode=code;Log("PENDING",null);}
 static string Failure(Exception error){
  Log("FAILED",error);
  return "安装未完成。\n错误阶段："+stage+"\n错误代码："+errorCode+"\nSAFE_MESSAGE：当前阶段未完成，请截图此窗口联系客服。\nQQ：89523844\n"+(logPath!=null&&File.Exists(logPath)?"诊断日志已保留。\n诊断日志："+logPath:"诊断日志无法写入，请保留此窗口截图。");
 }
 static void ChildFailure(){
  try{string path=Path.Combine(workspace,"diagnostic-status.txt");Safety.NoLinks(workspace,path);var lines=File.ReadAllLines(path);
   if(lines.Length==2&&Array.IndexOf(new[]{"PREFLIGHT","LICENSE","LICENSE_VERIFY","LICENSE_SELECT_ROUTE","LICENSE_START","LICENSE_COMPLETE","DOWNLOAD","PACKAGE_VERIFY","EXTRACT","INSTALL","CONFIG","CODEX_VERIFY","CLEANUP","FINAL_VERIFY","DESKTOP_VERIFY","UNEXPECTED"},lines[0])>=0&&System.Text.RegularExpressions.Regex.IsMatch(lines[1],"^[A-Z_]{1,64}$")){stage=lines[0];errorCode=lines[1];}
  }catch{}
 }
 static string workspace, temp, exe, config, models, configHash, modelsHash, version, installationTicket, clientType, providerType, appId;
 static string LoadInstallationTicket(){
  byte[] magic=System.Text.Encoding.ASCII.GetBytes("THZTICKETV1!");string self=Assembly.GetExecutingAssembly().Location;
  using(var stream=new FileStream(self,FileMode.Open,FileAccess.Read,FileShare.Read)){
   if(stream.Length<magic.Length+4+32)throw new InvalidOperationException("INSTALLATION_TICKET_MISSING");
   stream.Seek(-magic.Length,SeekOrigin.End);byte[] found=new byte[magic.Length];if(stream.Read(found,0,found.Length)!=found.Length)throw new InvalidOperationException("INSTALLATION_TICKET_INVALID");
   for(int i=0;i<magic.Length;i++)if(found[i]!=magic[i])throw new InvalidOperationException("INSTALLATION_TICKET_MISSING");
   stream.Seek(-(magic.Length+4),SeekOrigin.End);byte[] lengthBytes=new byte[4];if(stream.Read(lengthBytes,0,4)!=4)throw new InvalidOperationException("INSTALLATION_TICKET_INVALID");
   int length=BitConverter.ToInt32(lengthBytes,0);if(length<32||length>128||stream.Length<magic.Length+4+length)throw new InvalidOperationException("INSTALLATION_TICKET_INVALID");
   stream.Seek(-(magic.Length+4+length),SeekOrigin.End);byte[] bytes=new byte[length];if(stream.Read(bytes,0,length)!=length)throw new InvalidOperationException("INSTALLATION_TICKET_INVALID");
   string ticket=System.Text.Encoding.ASCII.GetString(bytes);if(!System.Text.RegularExpressions.Regex.IsMatch(ticket,"\\A[A-Za-z0-9_-]{32,128}\\z"))throw new InvalidOperationException("INSTALLATION_TICKET_INVALID");return ticket;
  }
 }
 static List<OwnedFile> owned=new List<OwnedFile>();
 static string Hash(string path){return Safety.Hash(path);}
 static void Track(string path){Safety.NoLinks(workspace,path);owned.Add(new OwnedFile(path,Hash(path)));}
 static void Notice(string text){if(CiTest){try{Console.Error.WriteLine("THZ_CI_NOTICE: "+text);}catch{}return;}MessageBox.Show(text,"特好装 · 测试安装程序",MessageBoxButtons.OK,MessageBoxIcon.Information);}
 static void Contact(){Notice("联系客服\nQQ：89523844\n可咨询获取激活码、安装问题、网络问题和使用问题。");}
 static void LogPostInstallLaunch(string result,Exception error){
  try{File.AppendAllText(logPath,DateTime.UtcNow.ToString("o")+" stage=POST_INSTALL_LAUNCH code="+(result=="PASS"?"NONE":"POST_INSTALL_LAUNCH_FAILED")+" exception="+(error==null?"NONE":error.GetType().FullName)+" result="+result+Environment.NewLine);}catch{}
 }
 static void LaunchCodexTerminal(){
  if(String.IsNullOrWhiteSpace(exe)||!File.Exists(exe))throw new InvalidOperationException("VERIFIED_CODEX_MISSING");
  string expected=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","OpenAI","Codex","bin","codex.exe");
  if(!String.Equals(Path.GetFullPath(exe),Path.GetFullPath(expected),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("VERIFIED_CODEX_PATH_INVALID");
 string command=Environment.GetEnvironmentVariable("ComSpec");
 if(String.IsNullOrWhiteSpace(command))command=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"cmd.exe");
  string arguments="/K \"\""+exe.Replace("\"","\"\"")+"\"\"";
  if(clientType=="cli"&&providerType=="deepseek"){
   // Codex may clear an incompatible pre-existing ChatGPT login and exit on
   // its first API-forced launch. Retry exactly once only when that first
   // process returns immediately; a normal interactive session is untouched.
   string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
   string literal=exe.Replace("'","''");
   string script="$started=[DateTime]::UtcNow; & '"+literal+"'; $elapsed=([DateTime]::UtcNow-$started).TotalSeconds; if($elapsed -le 15){ & '"+literal+"' }";
   string encoded=Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(script));
   arguments="/K \"\""+ps.Replace("\"","\"\"")+"\" -NoProfile -ExecutionPolicy Bypass -EncodedCommand "+encoded+"\"";
  }
  var info=new ProcessStartInfo(command,arguments){UseShellExecute=true,CreateNoWindow=false,WorkingDirectory=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),WindowStyle=ProcessWindowStyle.Normal};
  var launched=Process.Start(info);if(launched==null)throw new InvalidOperationException("POST_INSTALL_LAUNCH_FAILED");
  LogPostInstallLaunch("PASS",null);
 }
 static string ProductName { get { return providerType=="claude"?"Claude Desktop":providerType=="gemini"?"Gemini Desktop":clientType=="desktop"?"ChatGPT Desktop":"Codex"; } }
 static string RegistrationFunction {
  get { return providerType=="claude"?"Test-ClaudeDesktopRegistration":providerType=="gemini"?"Test-GeminiDesktopRegistration":"Test-OfficialCodexDesktopRegistration"; }
 }
 // Use the same registration checks as Runner, loaded from the hashed embedded
 // resource. This still works after cleanup removes the extracted scripts.
 static string DesktopRegistrationScript(){
  string source;using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("InstallerLibrary.ps1"))using(var reader=new StreamReader(stream)){source=reader.ReadToEnd();}
  string marker="function "+RegistrationFunction+" {";int start=source.IndexOf(marker,StringComparison.Ordinal);if(start<0)throw new InvalidOperationException("DESKTOP_VERIFIER_MISSING");
  int end=source.IndexOf("\nfunction ",start+marker.Length,StringComparison.Ordinal);if(end<0)throw new InvalidOperationException("DESKTOP_VERIFIER_MISSING");
  return "$ErrorActionPreference='Stop'; "+source.Substring(start,end-start)+"\n$p="+RegistrationFunction+"; ";
 }
 static string ProbeDesktop(string script){
  string encoded=Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(script));
  string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
  using(var p=new Process()){
   p.StartInfo=new ProcessStartInfo(ps,"-NoProfile -NonInteractive -EncodedCommand "+encoded){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
   p.Start();var output=p.StandardOutput.ReadToEndAsync();var error=p.StandardError.ReadToEndAsync();
   if(!p.WaitForExit(60000)){p.Kill();throw new InvalidOperationException("DESKTOP_VERIFY_TIMEOUT");}
   p.WaitForExit();lastExit=p.ExitCode;if(p.ExitCode!=0)throw new InvalidOperationException("DESKTOP_PACKAGE_VERIFY_FAILED");return output.Result.Trim();
  }
 }
 static void CiVerifyDesktopAppx(){
  string literal=appId.Replace("'","''");
  string script="$p=@(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -ceq '"+literal+"' }); if($p.Count -lt 1){exit 41}; [Console]::Out.Write($p[0].Version)";
  try {if(String.IsNullOrWhiteSpace(ProbeDesktop(script)))throw new InvalidOperationException("CI_APPX_REGISTRATION_MISSING");}
  catch {errorCode="CI_APPX_REGISTRATION_MISSING";throw new InvalidOperationException("CI_APPX_REGISTRATION_MISSING");}
 }
 static void LaunchCodexDesktop(){
  string script=DesktopRegistrationScript();
  if(providerType=="gemini")script+="Start-Process -FilePath $p.InstallPath -ErrorAction Stop";
  else {
   string id=providerType=="claude"?"Claude":null;
   script+=id!=null?"Start-Process ('shell:AppsFolder\\'+$p.PackageFamilyName+'!Claude') -ErrorAction Stop":"$pkg=Get-AppxPackage|Where-Object {$_.PackageFamilyName -eq $p.PackageFamilyName}|Select-Object -First 1;$m=Get-AppxPackageManifest $pkg;$id=@($m.Package.Applications.Application)[0].Id;Start-Process ('shell:AppsFolder\\'+$p.PackageFamilyName+'!'+$id) -ErrorAction Stop";
  }
  ProbeDesktop(script);LogPostInstallLaunch("PASS",null);
 }
 static bool ShowFinishDialog(string detail){
  using(var form=new Form()){form.Text=ProductName+" 已安装成功";form.Size=new Size(520,285);form.StartPosition=FormStartPosition.CenterScreen;form.FormBorderStyle=FormBorderStyle.FixedDialog;form.MaximizeBox=false;form.MinimizeBox=false;
   var label=new Label{Text="✓ "+ProductName+" 已安装成功\n版本："+version+"\n"+detail,Dock=DockStyle.Top,Height=130,Padding=new Padding(20),AutoSize=false};form.Controls.Add(label);
   var launch=new CheckBox{Text="安装完成后打开 "+ProductName,Checked=true,AutoSize=true,Left=24,Top=145};form.Controls.Add(launch);
   var finish=new Button{Text="完成",Width=120,Height=40,Left=365,Top=190,DialogResult=DialogResult.OK};form.Controls.Add(finish);form.AcceptButton=finish;
   form.ShowDialog();return launch.Checked;
  }
 }
 static void CompleteAndOptionallyLaunch(string detail){
  if(CiTest){Console.WriteLine("THZ_CI_RESULT=PASS");return;}
  if(providerType=="chatgpt")detail=(clientType=="desktop"?"Codex 桌面版已安装完成。\n请在 Codex 官方界面登录 ChatGPT / Codex 账号。":"Codex 终端版已安装完成。\n如尚未登录，请按 Codex 官方提示完成账号登录。")+"\n"+detail;
  if(!ShowFinishDialog(detail))return;
  while(true){try{if(clientType=="desktop")LaunchCodexDesktop();else LaunchCodexTerminal();return;}catch(Exception error){LogPostInstallLaunch("FAILED",error);var choice=Choice(ProductName+" 已安装成功",ProductName+" 已安装完成，但未能自动打开。\n你可以从开始菜单打开应用。",new[]{"重新启动","完成"});if(choice!="重新启动")return;}}
 }
 static string VerifyEmbeddedResource(string path,string expected) {
  Stage("EMBEDDED_RESOURCE_VERIFY","RESOURCE_VERIFY_UNEXPECTED");
  bool exists=false,started=false,completed=false;bool? match=null;long? size=null;string actual=null;Exception failure=null;
  try {
   errorCode="RESOURCE_PATH_INVALID";
   if(!Safety.Inside(workspace,path))throw new InvalidOperationException("RESOURCE_PATH_INVALID");
   errorCode="RESOURCE_FILE_READ_FAILED";
   try {var attr=File.GetAttributes(path);exists=true;if((attr&FileAttributes.Directory)!=0){errorCode="RESOURCE_PATH_INVALID";throw new InvalidOperationException("RESOURCE_PATH_INVALID");}}
   catch(FileNotFoundException){errorCode="RESOURCE_FILE_NOT_FOUND";throw;}
   catch(DirectoryNotFoundException){errorCode="RESOURCE_FILE_NOT_FOUND";throw;}
   errorCode="RESOURCE_PATH_INVALID";Safety.NoLinks(workspace,path);
   errorCode="RESOURCE_FILE_READ_FAILED";
   using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)) {
    size=stream.Length;
    errorCode="RESOURCE_HASH_CALC_FAILED";started=true;
    using(var sha=System.Security.Cryptography.SHA256.Create()) {
     try {actual=BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","");completed=true;}
     catch(IOException){errorCode="RESOURCE_FILE_READ_FAILED";throw;}
    }
   }
   errorCode="RESOURCE_EXPECTED_HASH_INVALID";
   if(expected==null||!System.Text.RegularExpressions.Regex.IsMatch(expected,@"\A[0-9a-fA-F]{64}\z"))throw new InvalidOperationException("RESOURCE_EXPECTED_HASH_INVALID");
   match=String.Equals(actual,expected,StringComparison.OrdinalIgnoreCase);
   if(!match.Value){errorCode="RESOURCE_HASH_MISMATCH";throw new InvalidOperationException("RESOURCE_HASH_MISMATCH");}
   errorCode="RESOURCE_PATH_INVALID";Safety.NoLinks(workspace,path);
   errorCode="RESOURCE_VERIFY_OK";return actual;
  } catch(FileNotFoundException e){errorCode="RESOURCE_FILE_NOT_FOUND";failure=e;throw;}
    catch(DirectoryNotFoundException e){errorCode="RESOURCE_FILE_NOT_FOUND";failure=e;throw;}
    catch(Exception e){failure=e;throw;}
  finally {
   try {
    string safePath=(path??"NONE").Replace("\r"," ").Replace("\n"," ");
    string expectedLog=expected!=null&&System.Text.RegularExpressions.Regex.IsMatch(expected,@"\A[0-9a-fA-F]{64}\z")?expected:"INVALID_OR_MISSING";
    File.AppendAllText(logPath,DateTime.UtcNow.ToString("o")+" stage=RESOURCE_VERIFY error_code="+errorCode+" exception_type="+(failure==null?"NONE":failure.GetType().FullName)+" resource_path="+safePath+" resource_exists="+exists+" resource_size="+(size.HasValue?size.Value.ToString():"UNKNOWN")+" expected_hash_present="+(!String.IsNullOrEmpty(expected))+" hash_calculation_started="+started+" hash_calculation_completed="+completed+" hash_match="+(match.HasValue?match.Value.ToString():"UNKNOWN")+(completed?" expected_sha256="+expectedLog+" actual_sha256="+actual:"")+Environment.NewLine);
   }catch{}
  }
 }

 static void ExtractResources() {
  foreach(var pair in Resources){
   Stage("EXTRACT","RESOURCE_EXTRACT_FAILED");
   string path=Path.GetFullPath(Path.Combine(workspace,pair.Key));
   using(var input=Assembly.GetExecutingAssembly().GetManifestResourceStream(pair.Key))
   using(var output=new FileStream(path,FileMode.CreateNew,FileAccess.Write)){
    if(input==null)throw new InvalidOperationException("RESOURCE_MISSING");
    input.CopyTo(output);
   }
   Log("PASS",null);
   string verifiedHash=VerifyEmbeddedResource(path,pair.Value);
   owned.Add(new OwnedFile(path,verifiedHash));
  }
 }
 static void Extract() {
  Stage("EXTRACT","WORKSPACE_CREATE_FAILED");
  string[] bases=new string[]{
   Path.GetTempPath(),
   Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"THZ","Workspace"),
   Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".thz-workspace")
  };
  string created=null;
  foreach(string b in bases){
   if(String.IsNullOrWhiteSpace(b))continue;
   string candidate=null;
   try{
    Directory.CreateDirectory(b);
    candidate=Path.Combine(b,"THZ-Codex-Setup-"+Guid.NewGuid().ToString("N"));
    if(CiTest)Console.WriteLine("THZ_CI_WORKSPACE_TRY="+candidate);
    if(Directory.Exists(candidate))throw new InvalidOperationException("WORKSPACE_EXISTS");
    try{
     var acl=new DirectorySecurity();
     acl.SetAccessRuleProtection(true,false);
     var user=WindowsIdentity.GetCurrent().User;
     if(user==null)throw new InvalidOperationException("WORKSPACE_IDENTITY_UNKNOWN");
     acl.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
     Directory.CreateDirectory(candidate,acl);
    }catch(Exception aclError){
     LogDetail("WORKSPACE_ACL_FALLBACK",candidate,aclError);
     Directory.CreateDirectory(candidate);
    }
    created=candidate;
    break;
   }catch(Exception e){
    LogDetail("WORKSPACE_BASE_FAILED",candidate??b,e);
   }
  }
  if(created==null)throw new InvalidOperationException("WORKSPACE_CREATE_FAILED");
  workspace=created;
  if(CiTest)Console.WriteLine("THZ_CI_WORKSPACE="+workspace);
  Log("PASS",null);
  ExtractResources();
  temp=Path.Combine(workspace,"download-temp");Directory.CreateDirectory(temp);
  Stage("EXTRACT","MANIFEST_WRITE_FAILED");Manifest(false);
 }
 static void Manifest(bool verified){
  string path=Path.Combine(workspace,"cleanup-manifest.xml");
  using(var x=XmlWriter.Create(path,new XmlWriterSettings{Indent=true})){
   x.WriteStartElement("CleanupManifest");x.WriteAttributeString("Workspace",workspace);
   foreach(var e in owned){x.WriteStartElement("File");x.WriteAttributeString("Path",e.Path);x.WriteAttributeString("SHA256",e.Hash);x.WriteAttributeString("CREATED_BY_THIS_INSTALL","true");x.WriteAttributeString("SAFE_TO_DELETE","true");x.WriteEndElement();}
   x.WriteStartElement("Directory");x.WriteAttributeString("Path",temp);x.WriteAttributeString("CREATED_BY_THIS_INSTALL","true");x.WriteAttributeString("Policy","REMOVE_ONLY_IF_EMPTY; UNKNOWN_CONTENT_MUST_KEEP");x.WriteEndElement();
   if(verified)foreach(string keep in new[]{exe,config,models,Assembly.GetExecutingAssembly().Location})if(!String.IsNullOrWhiteSpace(keep)){x.WriteStartElement("File");x.WriteAttributeString("Path",keep);x.WriteAttributeString("MUST_KEEP","true");x.WriteEndElement();}
   x.WriteEndElement();
  }
 }
 static string NormalizePathEntry(string value) {
  try {return Path.GetFullPath(Environment.ExpandEnvironmentVariables(value.Trim().Trim(new char[]{'"'}))).TrimEnd(new char[]{'\\','/'});}catch{return "";}
 }
 static string AppendUserPath(string original,string bin) {
  foreach(string entry in (original??"").Split(new char[]{';'}))
   if(!String.IsNullOrWhiteSpace(entry)&&String.Equals(NormalizePathEntry(entry),NormalizePathEntry(bin),StringComparison.OrdinalIgnoreCase))return original;
  return String.IsNullOrEmpty(original)?bin:original+(original.EndsWith(";")?"":";")+bin;
 }
 [System.Runtime.InteropServices.DllImport("user32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode,SetLastError=true)]
 static extern IntPtr SendMessageTimeout(IntPtr h,uint m,UIntPtr w,string l,uint flags,uint timeout,out UIntPtr result);
 static string PersistentPath() {
  return Environment.ExpandEnvironmentVariables((Environment.GetEnvironmentVariable("Path",EnvironmentVariableTarget.Machine)??"")+";"+(Environment.GetEnvironmentVariable("Path",EnvironmentVariableTarget.User)??""));
 }
 static void EnsureUserPath() {
  if(!File.Exists(exe))throw new InvalidOperationException("CODEX_EXECUTABLE_MISSING");
  string bin=Path.GetDirectoryName(Path.GetFullPath(exe));
  using(var key=Microsoft.Win32.Registry.CurrentUser.CreateSubKey("Environment")){
   object raw=key.GetValue("Path",null,Microsoft.Win32.RegistryValueOptions.DoNotExpandEnvironmentNames);
   if(raw!=null&&!(raw is string))throw new InvalidOperationException("USER_PATH_TYPE_INVALID");
   string before=(string)raw;string after=AppendUserPath(before,bin);
   if(!String.Equals(before,after,StringComparison.Ordinal)){
    var kind=raw==null?Microsoft.Win32.RegistryValueKind.ExpandString:key.GetValueKind("Path");
    key.SetValue("Path",after,kind);key.Flush();
    if(!String.Equals((string)key.GetValue("Path",null,Microsoft.Win32.RegistryValueOptions.DoNotExpandEnvironmentNames),after,StringComparison.Ordinal))throw new InvalidOperationException("USER_PATH_PERSIST_FAILED");
   }
  }
  Environment.SetEnvironmentVariable("Path",PersistentPath(),EnvironmentVariableTarget.Process);
  UIntPtr result;SendMessageTimeout(new IntPtr(0xffff),0x001a,UIntPtr.Zero,"Environment",2,2000,out result);
 }
 static void ProbeUserPath() {
  string script="$ErrorActionPreference='Stop'; try { $command=Get-Command codex -CommandType Application -ErrorAction Stop; if(-not [string]::Equals([IO.Path]::GetFullPath($command.Source),$env:THZ_EXPECTED_CODEX,[StringComparison]::OrdinalIgnoreCase)){exit 21}; & codex --version; exit $LASTEXITCODE } catch { exit 22 }";
  string encoded=Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(script));
  string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
  using(var p=new Process()){
   p.StartInfo=new ProcessStartInfo(ps,"-NoProfile -NonInteractive -EncodedCommand "+encoded){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=Environment.GetFolderPath(Environment.SpecialFolder.System)};
   p.StartInfo.EnvironmentVariables["Path"]=PersistentPath();
   p.StartInfo.EnvironmentVariables["THZ_EXPECTED_CODEX"]=Path.GetFullPath(exe);
   p.Start();var output=p.StandardOutput.ReadToEndAsync();var error=p.StandardError.ReadToEndAsync();
   if(!p.WaitForExit(30000)){p.Kill();throw new InvalidOperationException("USER_PATH_PROBE_TIMEOUT");}
   p.WaitForExit();lastExit=p.ExitCode;
   string detected=Safety.Version(p.ExitCode,output.Result+"\n"+error.Result);
   if(detected!=version)throw new InvalidOperationException("USER_PATH_VERSION_MISMATCH");
  }
 }

 static string Probe() {
  string expected=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","OpenAI","Codex","bin","codex.exe");
  if(!String.Equals(Path.GetFullPath(exe),Path.GetFullPath(expected),StringComparison.OrdinalIgnoreCase)||!File.Exists(exe))throw new InvalidOperationException("VERIFY_PATH");
  using(var p=new Process()){p.StartInfo=new ProcessStartInfo(exe,"--version"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};p.Start();Task<string> output=p.StandardOutput.ReadToEndAsync(),error=p.StandardError.ReadToEndAsync();if(!p.WaitForExit(30000)){p.Kill();throw new InvalidOperationException("VERIFY_TIMEOUT");}p.WaitForExit();lastExit=p.ExitCode;return Safety.Version(p.ExitCode,output.Result+"\n"+error.Result);}
 }
 static void Verify(bool readProof){
  using(var f=new Form()){f.Text="正在验证 Codex";f.Size=new Size(440,150);f.StartPosition=FormStartPosition.CenterScreen;f.ControlBox=false;f.Controls.Add(new Label{Dock=DockStyle.Fill,Text="正在确认 Codex 是否安装成功…",TextAlign=ContentAlignment.MiddleCenter});f.Show();f.Refresh();VerifyCore(readProof);}
 }
 static string ProofValue(XmlDocument proof,string name,bool required){
  var node=proof.SelectSingleNode("/Verification/"+name);if(node==null){if(required)throw new InvalidOperationException("VERIFICATION_FIELD_MISSING");return "";}return node.InnerText;
 }
 static void VerifyCore(bool readProof){
  if(readProof){
   string proof=Path.Combine(workspace,"verification.xml");Safety.NoLinks(workspace,proof);var x=new XmlDocument();x.XmlResolver=null;
   using(var reader=XmlReader.Create(proof,new XmlReaderSettings{DtdProcessing=DtdProcessing.Prohibit,XmlResolver=null})){x.Load(reader);}
   clientType=ProofValue(x,"ClientType",true);providerType=ProofValue(x,"ProviderType",true);appId=ProofValue(x,"AppId",true);version=ProofValue(x,"Version",true);
   if(clientType!="cli"&&clientType!="desktop")throw new InvalidOperationException("CLIENT_TYPE_INVALID");
   if(providerType!="chatgpt"&&providerType!="deepseek"&&providerType!="claude"&&providerType!="gemini")throw new InvalidOperationException("PROVIDER_INVALID");
   if(clientType!="desktop"&&(providerType=="claude"||providerType=="gemini"))throw new InvalidOperationException("INSTALL_PLAN_MISMATCH");
   exe=ProofValue(x,"Executable",clientType!="desktop");config=ProofValue(x,"Config",clientType!="desktop");models=ProofValue(x,"Models",clientType!="desktop");configHash=ProofValue(x,"ConfigHash",clientType!="desktop");modelsHash=ProofValue(x,"ModelsHash",clientType!="desktop");
  }
  if(clientType=="desktop"){
   if(String.IsNullOrWhiteSpace(appId))throw new InvalidOperationException("DESKTOP_APP_REGISTRATION_INVALID");
   string script=DesktopRegistrationScript();string literal=appId.Replace("'","''");
   if(providerType=="gemini")script+="if(-not [string]::Equals($p.InstallPath,'"+literal+"',[StringComparison]::OrdinalIgnoreCase)){exit 31};";
   else script+="if($p.PackageFamilyName -cne '"+literal+"'){exit 31};";
   script+="[Console]::Out.Write($p.Version)";string registeredVersion=ProbeDesktop(script);
   if(String.IsNullOrWhiteSpace(registeredVersion)||registeredVersion!=version)throw new InvalidOperationException("DESKTOP_VERSION_MISMATCH");
   Log("DESKTOP_PACKAGE_VERIFY_PASS",null);return;
  }
  string home=Environment.GetEnvironmentVariable("CODEX_HOME");if(String.IsNullOrWhiteSpace(home))home=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".codex");
  if(!Path.IsPathRooted(home)||Safety.Inside(workspace,home)||!String.Equals(Path.GetFullPath(config),Path.Combine(Path.GetFullPath(home),"config.toml"),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("CONFIG_PATH");
  if(providerType=="deepseek"&&(String.IsNullOrWhiteSpace(models)||!String.Equals(Path.GetFullPath(models),Path.Combine(Path.GetFullPath(home),"models.json"),StringComparison.OrdinalIgnoreCase)))throw new InvalidOperationException("CONFIG_PATH");
  if(providerType=="chatgpt"&&!String.IsNullOrWhiteSpace(models)&&!String.Equals(Path.GetFullPath(models),Path.Combine(Path.GetFullPath(home),"models.json"),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("CONFIG_PATH");
  version=Probe();Log("ABSOLUTE_PATH_VERIFY_PASS",null);
  if(Hash(config)!=configHash||(!String.IsNullOrWhiteSpace(models)&&(Hash(models)!=modelsHash)))throw new InvalidOperationException("CONFIG_CHANGED");
  Stage("CODEX_VERIFY","CODEX_PATH_NOT_AVAILABLE");if(readProof)EnsureUserPath();ProbeUserPath();Log("USER_PATH_VERIFY_PASS",null);
 }
 static bool RunInstaller(){
  Stage("EMBEDDED_RESOURCE_VERIFY","RESOURCE_VALIDATION_FAILED");
  foreach(var pair in Resources){var path=Path.Combine(workspace,pair.Key);VerifyEmbeddedResource(path,pair.Value);}
  string proof=Path.Combine(workspace,"verification.xml");if(File.Exists(proof))throw new InvalidOperationException("STALE_PROOF");
  Stage("PREFLIGHT","POWERSHELL_LAUNCH_FAILED");
  string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
  using(var progress=new Form()){progress.Text="特好装";progress.Size=new Size(460,180);progress.StartPosition=FormStartPosition.CenterScreen;progress.ControlBox=false;progress.Controls.Add(new Label{Dock=DockStyle.Fill,Text="正在运行测试安装向导…\n完成后将独立验证 Codex。",TextAlign=ContentAlignment.MiddleCenter});progress.Show();progress.Refresh();
   using(var process=new Process()){process.StartInfo=new ProcessStartInfo(ps,"-NoProfile -STA -ExecutionPolicy Bypass -File \""+Path.Combine(workspace,"Runner.ps1")+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=workspace};process.StartInfo.EnvironmentVariables["THZ_DIAGNOSTIC_LOG"]=logPath;process.StartInfo.EnvironmentVariables["THZ_INSTALL_TICKET"]=installationTicket;process.StartInfo.EnvironmentVariables["TEMP"]=temp;process.StartInfo.EnvironmentVariables["TMP"]=temp;
    // Never persist raw child output, HTTP errors, secrets, or command-line credentials.
    process.OutputDataReceived+=(s,e)=>{};process.ErrorDataReceived+=(s,e)=>{};process.Start();process.BeginOutputReadLine();process.BeginErrorReadLine();while(!process.WaitForExit(100)){Application.DoEvents();}process.WaitForExit();lastExit=process.ExitCode;if(process.ExitCode!=0){errorCode=process.ExitCode==2?"USER_CANCELLED":"CHILD_PROCESS_FAILED";ChildFailure();Log("FAILED",null);}return process.ExitCode==0;
   }
  }
 }
 static string Choice(string title,string text,string[] labels){string result=null;using(var f=new Form()){f.Text=title;f.Size=new Size(560,340);f.StartPosition=FormStartPosition.CenterScreen;f.FormBorderStyle=FormBorderStyle.FixedDialog;f.MaximizeBox=false;var label=new Label{Text=text,Dock=DockStyle.Top,Height=155,Padding=new Padding(20),AutoSize=false};f.Controls.Add(label);var buttons=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=120,Padding=new Padding(12)};foreach(var name in labels){var button=new Button{Text=name,AutoSize=true,Height=42,MinimumSize=new Size(115,42)};button.Click+=(s,e)=>{result=name;f.Close();};buttons.Controls.Add(button);}f.Controls.Add(buttons);f.ShowDialog();}return result;}
 [STAThread] public static void Main(){
  if(Environment.OSVersion.Platform!=PlatformID.Win32NT)return;
  Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
  try{InitLog();Stage("LICENSE","INSTALLATION_TICKET_INVALID");installationTicket=LoadInstallationTicket();Extract();bool installed=RunInstaller();installationTicket=null;bool verified=false;
   while(!verified){try{if(!installed)throw new InvalidOperationException("INSTALL_FAILED");Stage(clientType=="desktop"?"DESKTOP_VERIFY":"CODEX_VERIFY","INSTALLATION_VERIFY_FAILED");Verify(true);Log("PASS",null);if(CiTest&&clientType=="desktop"&&providerType!="gemini")CiVerifyDesktopAppx();verified=true;}catch(Exception error){
    if(CiTest){Log("FAILED",error);try{Console.Error.WriteLine("THZ_CI_RESULT=FAIL stage="+stage+" code="+errorCode);}catch{}Environment.Exit(2);}else{var choice=Choice("安装未完成",Failure(error),new[]{"重试检测","重试安装","查看解决办法","联系客服","退出"});
    if(choice=="重试检测"){installed=true;continue;}if(choice=="重试安装"){Extract();installed=RunInstaller();continue;}if(choice=="联系客服"){Contact();continue;}if(choice=="查看解决办法"){Notice("请确认官方安装资源网络可用、测试授权有效，且不存在旧版安装冲突。\n不要关闭系统安全功能。\n诊断目录："+workspace);continue;}return;}
   }}
   Stage("CLEANUP","CLEANUP_MANIFEST_FAILED");Track(Path.Combine(workspace,"verification.xml"));Manifest(true);Track(Path.Combine(workspace,"cleanup-manifest.xml"));
   var action=CiTest?"暂时保留":Choice(ProductName+" 已安装成功","✓ "+ProductName+" 已安装成功\n版本："+version+"\n是否清理本次安装的临时文件？应用及用户配置会保留。",new[]{"立即清理","暂时保留"});
   if(action!="立即清理"){CompleteAndOptionallyLaunch("临时文件已保留。\n下载的安装程序可手动删除，不影响已安装的应用。");if(CiTest)Environment.Exit(0);return;}
   Stage("CODEX_VERIFY","PRE_CLEANUP_VERIFY_FAILED");Verify(false);Stage("CLEANUP","CLEANUP_SAFETY_CHECK_FAILED");Safety.Cleanup(workspace,owned);
   // Never traverse or remove untracked files, links, or directories recursively.
   Safety.NoLinks(workspace,temp);if(Directory.GetFileSystemEntries(temp).Length==0)Directory.Delete(temp,false);
   bool leftovers=Directory.GetFileSystemEntries(workspace).Length>0;if(!leftovers)Directory.Delete(workspace,false);
   Stage("FINAL_VERIFY","POST_CLEANUP_VERIFY_FAILED");Verify(false);Log("PASS",null);CompleteAndOptionallyLaunch("清理后再次验证通过。\n应用与用户配置均已保留。"+(leftovers?"\n未追踪的文件已安全保留。":""));
  }catch(Exception error){if(CiTest){Log("FAILED",error);try{Console.Error.WriteLine("THZ_CI_RESULT=FAIL stage="+stage+" code="+errorCode);}catch{}Environment.Exit(1);}Notice(Failure(error));}
 }
}
