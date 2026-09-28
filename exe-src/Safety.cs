using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
public sealed class OwnedFile { public string Path, Hash; public OwnedFile(string path,string hash){Path=path;Hash=hash;} }
public static class Safety {
 public static string Hash(string path) { using(var s=File.OpenRead(path)) using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(s)).Replace("-", ""); }
 public static string Version(int exitCode,string output) {
  if(exitCode!=0)throw new InvalidOperationException("VERIFY_EXIT_CODE");
  var m=Regex.Match(output,@"^(?:codex-cli|Codex CLI)\s+v?(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)\s*$",RegexOptions.Multiline|RegexOptions.IgnoreCase);
  if(!m.Success)throw new InvalidOperationException("VERIFY_INVALID_VERSION");return m.Groups[1].Value;
 }
 public static bool Inside(string root,string path) { return System.IO.Path.GetFullPath(path).StartsWith(System.IO.Path.GetFullPath(root).TrimEnd(new char[] { System.IO.Path.DirectorySeparatorChar })+System.IO.Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase); }
 public static void NoLinks(string root,string path) {
  if(!Inside(root,path))throw new InvalidOperationException("OUTSIDE_WORKSPACE");
  string current=System.IO.Path.GetFullPath(path), stop=System.IO.Path.GetFullPath(root);
  while(true){if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)throw new InvalidOperationException("REPARSE_POINT");if(current.Equals(stop,StringComparison.OrdinalIgnoreCase))break;current=System.IO.Path.GetDirectoryName(current);}
 }
 public static int Cleanup(string root,List<OwnedFile> entries) {
  // Validate the entire manifest before deleting anything. Never recursively delete.
  foreach(var e in entries){NoLinks(root,e.Path);if(Hash(e.Path)!=e.Hash)throw new InvalidOperationException("RESOURCE_CHANGED");}
  foreach(var e in entries){NoLinks(root,e.Path);if(Hash(e.Path)!=e.Hash)throw new InvalidOperationException("RESOURCE_CHANGED");File.Delete(e.Path);}
  return entries.Count;
 }
}
