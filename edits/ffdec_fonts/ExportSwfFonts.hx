package;
import haxe.crypto.Md5;
import haxe.io.BytesBuffer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.Process;
import sys.io.File;

class ExportSwfFonts
{
    static function main() : Void
    {
        var options = parseArgs(Sys.args());
        var projectRoot = findProjectRoot();
        var cacheRoot = Path.join([projectRoot,"bin","obj","ffdec_fonts"]);
        var stampRoot = Path.join([cacheRoot,".stamps"]);
        var librariesPath = Path.join([projectRoot,"generated_swf_libraries.xml"]);
        var ffdec = resolveFfdec(options.ffdec,projectRoot);
        var libraries = readLibraries(projectRoot,librariesPath);
        var exporterFiles = [
            Path.join([projectRoot,"edits","ffdec_fonts","ExportSwfFonts.hx"]),
            Path.join([projectRoot,"edits","ffdec_fonts","export_swf_fonts.hxml"])
        ];

        ensureDirectory(cacheRoot);
        ensureDirectory(stampRoot);
        var exporterHash = hashFiles(exporterFiles);
        var ffdecHash = ffdec != null && FileSystem.exists(ffdec.path) ? hashFile(ffdec.path) : "";
        adoptExistingFonts(projectRoot,cacheRoot,stampRoot,libraries,options.force,exporterHash,ffdecHash);

        var stale = 0;
        for(library in libraries)
        {
            var source = Path.normalize(Path.join([projectRoot,library.swfPath]));
            if(FileSystem.exists(source) && (options.force || !isUpToDate(source,stampPath(stampRoot,library.id),exporterHash,ffdecHash,ffdec != null)))
            {
                stale++;
            }
        }
        if(stale > 0 && ffdec == null)
        {
            Sys.println("FFDec not found; " + stale + " SWF(s) need a font export. Set FFDEC_HOME or pass --ffdec.");
            Sys.exit(1);
        }

        var exported = new Map<String,Bool>();
        var count = 0;
        var skipped = 0;
        var failed = 0;

        for(library in libraries)
        {
            var result = exportSwf(ffdec,projectRoot,cacheRoot,stampRoot,exporterHash,ffdecHash,library,exported,options.force);
            if(result == true) count++;
            else if(result == false) failed++;
            else skipped++;
        }

        cleanupRemovedLibraries(cacheRoot,stampRoot,libraries);

        var runtimeRoot = getRuntimeFontRoot(projectRoot);
        if(runtimeRoot != null)
        {
            syncCacheToRuntime(cacheRoot,runtimeRoot);
        }

        if(failed > 0)
        {
            Sys.println("Done. Exported " + count + ", skipped " + skipped + ", failed " + failed + ".");
            Sys.exit(1);
        }

        Sys.println("Done. Exported font folders for " + count + " SWF(s), skipped " + skipped + (runtimeRoot == null ? " (no cpp bin/ to sync)" : "; synced to " + runtimeRoot) + ".");
    }

    static function parseArgs(args:Array<String>) : {ffdec:String, force:Bool}
    {
        var ffdec:String = null;
        var force = false;
        var i = 0;
        while(i < args.length)
        {
            var arg = args[i];
            if((arg == "--ffdec" || arg == "-ffdec") && i + 1 < args.length)
            {
                ffdec = args[i + 1];
                i += 2;
                continue;
            }
            if(arg == "--force" || arg == "-force")
            {
                force = true;
                i++;
                continue;
            }
            i++;
        }
        return {ffdec:ffdec, force:force};
    }

    static function findProjectRoot() : String
    {
        var cwd = Sys.getCwd();
        while(cwd != null && cwd.length > 0)
        {
            if(FileSystem.exists(Path.join([cwd,"project.xml"])) && FileSystem.exists(Path.join([cwd,"generated_swf_libraries.xml"])))
            {
                return cwd;
            }
            var parent = Path.directory(Path.removeTrailingSlashes(cwd));
            if(parent == cwd)
            {
                break;
            }
            cwd = parent;
        }
        return Sys.getCwd();
    }

    static function readLibraries(projectRoot:String, librariesPath:String) : Array<{swfPath:String, id:String}>
    {
        var libraries = new Array<{swfPath:String, id:String}>();
        var seen = new Map<String,Bool>();
        if(FileSystem.exists(librariesPath))
        {
            addLibrariesFromXml(Xml.parse(File.getContent(librariesPath)),libraries,seen,false);
        }
        addLibrariesFromXml(Xml.parse(File.getContent(Path.join([projectRoot,"project.xml"]))),libraries,seen,true);
        return libraries;
    }

    static function addLibrariesFromXml(xml:Xml, libraries:Array<{swfPath:String, id:String}>, seen:Map<String,Bool>, allowMissingId:Bool) : Void
    {
        for(node in xml.elementsNamed("project"))
        {
            for(library in node.elementsNamed("library"))
            {
                var swfPath = library.get("path");
                if(swfPath == null || !StringTools.endsWith(swfPath.toLowerCase(),".swf"))
                {
                    continue;
                }
                var id = library.get("id");
                if(id == null || id.length == 0)
                {
                    if(!allowMissingId)
                    {
                        continue;
                    }
                    id = getProjectLibraryId(swfPath);
                }
                var key = Path.normalize(swfPath) + "|" + id;
                if(seen.exists(key))
                {
                    continue;
                }
                seen.set(key,true);
                libraries.push({swfPath:swfPath, id:id});
            }
        }
    }

    static function exportSwf(ffdec:FfdecTool, projectRoot:String, cacheRoot:String, stampRoot:String, exporterHash:String, ffdecHash:String, library:{swfPath:String, id:String}, exported:Map<String,Bool>, force:Bool) : Null<Bool>
    {
        var source = Path.normalize(Path.join([projectRoot,library.swfPath]));
        if(!FileSystem.exists(source))
        {
            return null;
        }

        var key = Path.normalize(library.swfPath) + "|" + library.id;
        if(exported.exists(key))
        {
            return null;
        }
        exported.set(key,true);

        if(!force && isUpToDate(source,stampPath(stampRoot,library.id),exporterHash,ffdecHash,ffdec != null))
        {
            return null;
        }

        var outDir = Path.normalize(Path.join([cacheRoot,library.id]));
        deleteDirectory(outDir);
        ensureDirectory(outDir);
        Sys.println("Export fonts: " + library.swfPath);
        var code = runFfdec(ffdec,["-onerror","ignore","-format","font:ttf","-export","font",outDir,source]);
        if(code == 0)
        {
            removeDeviceFonts(outDir);
            deleteDirectoryIfEmpty(outDir);
            writeStamp(stampPath(stampRoot,library.id),source,exporterHash,ffdecHash);
            return true;
        }

        Sys.println("  ffdec failed with code " + code);
        return false;
    }

    static function isUpToDate(source:String, stamp:String, exporterHash:String, ffdecHash:String, checkFfdec:Bool) : Bool
    {
        if(!FileSystem.exists(stamp))
        {
            return false;
        }
        var expected = stampPayload(source,exporterHash,ffdecHash);
        var actual = parseStamp(File.getContent(stamp));
        if(actual == null || actual.swf != expected.swf || actual.exporter != expected.exporter)
        {
            return false;
        }
        return !checkFfdec || actual.ffdec == expected.ffdec;
    }

    static function writeStamp(stamp:String, source:String, exporterHash:String, ffdecHash:String) : Void
    {
        var payload = stampPayload(source,exporterHash,ffdecHash);
        File.saveContent(stamp,"swf=" + payload.swf + "\nexporter=" + payload.exporter + "\nffdec=" + payload.ffdec + "\n");
    }

    static function stampPayload(source:String, exporterHash:String, ffdecHash:String) : {swf:String, exporter:String, ffdec:String}
    {
        return {swf:hashFile(source), exporter:exporterHash, ffdec:ffdecHash};
    }

    static function parseStamp(content:String) : Null<{swf:String, exporter:String, ffdec:String}>
    {
        var swf = "";
        var exporter = "";
        var ffdec = "";
        var sawFingerprint = false;
        for(line in content.split("\n"))
        {
            var trimmed = StringTools.trim(line);
            if(StringTools.startsWith(trimmed,"swf="))
            {
                swf = trimmed.substr(4);
                sawFingerprint = true;
            }
            else if(StringTools.startsWith(trimmed,"exporter="))
            {
                exporter = trimmed.substr(9);
                sawFingerprint = true;
            }
            else if(StringTools.startsWith(trimmed,"ffdec="))
            {
                ffdec = trimmed.substr(6);
                sawFingerprint = true;
            }
        }
        if(!sawFingerprint)
        {
            return null;
        }
        return {swf:swf, exporter:exporter, ffdec:ffdec};
    }

    static function hashFiles(paths:Array<String>) : String
    {
        var hashes = [];
        for(path in paths)
        {
            if(FileSystem.exists(path))
            {
                hashes.push(hashTextFile(path));
            }
        }
        return Md5.encode(hashes.join(","));
    }

    static function hashFile(path:String) : String
    {
        return Md5.make(File.getBytes(path)).toHex();
    }

    // Strip CR so Windows checkouts match Linux stamps.
    static function hashTextFile(path:String) : String
    {
        var bytes = File.getBytes(path);
        var out = new BytesBuffer();
        var i = 0;
        var len = bytes.length;
        while(i < len)
        {
            var b = bytes.get(i);
            if(b != 13)
            {
                out.addByte(b);
            }
            i++;
        }
        return Md5.make(out.getBytes()).toHex();
    }

    static function stampPath(stampRoot:String, id:String) : String
    {
        return Path.join([stampRoot,id]);
    }

    static function adoptExistingFonts(projectRoot:String, cacheRoot:String, stampRoot:String, libraries:Array<{swfPath:String, id:String}>, force:Bool, exporterHash:String, ffdecHash:String) : Void
    {
        if(force || hasStamps(stampRoot))
        {
            return;
        }

        var imported = false;
        imported = importFontTree(Path.join([projectRoot,"Resources","ffdec_fonts"]),cacheRoot) || imported;
        imported = importFontTree(getRuntimeFontRoot(projectRoot),cacheRoot) || imported;
        if(!imported && !hasFontFolders(cacheRoot))
        {
            return;
        }

        for(library in libraries)
        {
            var source = Path.normalize(Path.join([projectRoot,library.swfPath]));
            if(!FileSystem.exists(source))
            {
                continue;
            }
            writeStamp(stampPath(stampRoot,library.id),source,exporterHash,ffdecHash);
        }
        Sys.println("Adopted existing fonts into " + cacheRoot + ".");
    }

    static function hasStamps(stampRoot:String) : Bool
    {
        if(!FileSystem.exists(stampRoot) || !FileSystem.isDirectory(stampRoot))
        {
            return false;
        }
        return FileSystem.readDirectory(stampRoot).length > 0;
    }

    static function hasFontFolders(cacheRoot:String) : Bool
    {
        if(!FileSystem.exists(cacheRoot) || !FileSystem.isDirectory(cacheRoot))
        {
            return false;
        }
        for(name in FileSystem.readDirectory(cacheRoot))
        {
            if(name == ".stamps")
            {
                continue;
            }
            var path = Path.join([cacheRoot,name]);
            if(FileSystem.isDirectory(path) && FileSystem.readDirectory(path).length > 0)
            {
                return true;
            }
        }
        return false;
    }

    static function importFontTree(from:String, cacheRoot:String) : Bool
    {
        if(from == null || !FileSystem.exists(from) || !FileSystem.isDirectory(from))
        {
            return false;
        }
        var imported = false;
        for(name in FileSystem.readDirectory(from))
        {
            if(name == ".stamps")
            {
                continue;
            }
            var src = Path.join([from,name]);
            if(!FileSystem.isDirectory(src))
            {
                continue;
            }
            var dest = Path.join([cacheRoot,name]);
            if(!FileSystem.exists(dest))
            {
                copyDirectory(src,dest);
                imported = true;
            }
        }
        return imported;
    }

    static function cleanupRemovedLibraries(cacheRoot:String, stampRoot:String, libraries:Array<{swfPath:String, id:String}>) : Void
    {
        var keep = new Map<String,Bool>();
        for(library in libraries)
        {
            keep.set(library.id,true);
        }
        if(FileSystem.exists(stampRoot))
        {
            for(name in FileSystem.readDirectory(stampRoot))
            {
                if(!keep.exists(name))
                {
                    FileSystem.deleteFile(Path.join([stampRoot,name]));
                }
            }
        }
        if(FileSystem.exists(cacheRoot))
        {
            for(name in FileSystem.readDirectory(cacheRoot))
            {
                if(name == ".stamps" || keep.exists(name))
                {
                    continue;
                }
                var path = Path.join([cacheRoot,name]);
                if(FileSystem.isDirectory(path))
                {
                    deleteDirectory(path);
                }
            }
        }
    }

    static function isSuffixedMacApp(name:String) : Bool
    {
        return StringTools.endsWith(name,"-x86_64.app")
            || StringTools.endsWith(name,"-arm64.app")
            || StringTools.endsWith(name,"-aarch64.app");
    }

    static function getRuntimeFontRoot(projectRoot:String) : String
    {
        var host = Sys.systemName();
        var platform = switch(host)
        {
            case "Windows": "windows";
            case "Mac": "macos";
            default: "linux";
        }
        var binRoot = Path.join([projectRoot,"bin",platform,"bin"]);
        if(!FileSystem.exists(binRoot) || !FileSystem.isDirectory(binRoot))
        {
            return null;
        }
        if(host == "Mac")
        {
            // Lime writes the unsuffixed .app; arch builds rename it afterwards.
            // Do not sync into *-x86_64.app / *-arm64.app or the second arch misses fonts.
            for(name in FileSystem.readDirectory(binRoot))
            {
                if(!StringTools.endsWith(name,".app") || isSuffixedMacApp(name))
                {
                    continue;
                }
                var resources = Path.join([binRoot,name,"Contents","Resources"]);
                if(FileSystem.exists(resources))
                {
                    return Path.join([resources,"ffdec_fonts"]);
                }
            }
            return null;
        }
        return Path.join([binRoot,"Resources","ffdec_fonts"]);
    }

    static function syncCacheToRuntime(cacheRoot:String, runtimeRoot:String) : Void
    {
        ensureDirectory(runtimeRoot);
        var keep = new Map<String,Bool>();
        for(name in FileSystem.readDirectory(cacheRoot))
        {
            if(name == ".stamps")
            {
                continue;
            }
            var src = Path.join([cacheRoot,name]);
            if(!FileSystem.isDirectory(src) || FileSystem.readDirectory(src).length == 0)
            {
                continue;
            }
            keep.set(name,true);
            var dest = Path.join([runtimeRoot,name]);
            deleteDirectory(dest);
            copyDirectory(src,dest);
        }
        if(FileSystem.exists(runtimeRoot))
        {
            for(name in FileSystem.readDirectory(runtimeRoot))
            {
                if(keep.exists(name))
                {
                    continue;
                }
                var path = Path.join([runtimeRoot,name]);
                if(FileSystem.isDirectory(path))
                {
                    deleteDirectory(path);
                }
            }
        }
    }

    static function getProjectLibraryId(swfPath:String) : String
    {
        return Path.withoutExtension(Path.withoutDirectory(swfPath));
    }

    static function resolveFfdec(explicit:String, projectRoot:String) : FfdecTool
    {
        var candidates = new Array<String>();
        addFfdecCandidates(candidates,explicit);
        addFfdecCandidates(candidates,Sys.getEnv("FFDEC_HOME"));
        var sibling = Path.join([Path.directory(Path.removeTrailingSlashes(projectRoot)),"jpexs-decompiler"]);
        candidates.push(Path.join([sibling,"dist","ffdec.jar"]));
        candidates.push(Path.join([sibling,"dist","ffdec-cli.jar"]));
        candidates.push(Path.join([sibling,"resources","ffdec.sh"]));
        var pathTool = findOnPath("ffdec");
        if(pathTool != null) candidates.push(pathTool);
        pathTool = findOnPath("ffdec.sh");
        if(pathTool != null) candidates.push(pathTool);
        pathTool = findOnPath("ffdec.bat");
        if(pathTool != null) candidates.push(pathTool);
        candidates.push("/usr/share/ffdec/ffdec.sh");
        candidates.push("/usr/bin/ffdec");
        candidates.push("/opt/ffdec/ffdec.sh");
        var home = Sys.getEnv("HOME");
        if(home != null)
        {
            candidates.push(Path.join([home,"FFDec","ffdec.sh"]));
        }
        for(path in candidates)
        {
            if(path != null && FileSystem.exists(path) && !FileSystem.isDirectory(path))
            {
                return {path:Path.normalize(path), jar:StringTools.endsWith(path.toLowerCase(),".jar")};
            }
        }
        return null;
    }

    static function addFfdecCandidates(candidates:Array<String>, value:String) : Void
    {
        if(value == null || value.length == 0)
        {
            return;
        }
        if(FileSystem.exists(value) && !FileSystem.isDirectory(value))
        {
            candidates.push(value);
            return;
        }
        candidates.push(Path.join([value,"ffdec.sh"]));
        candidates.push(Path.join([value,"ffdec"]));
        candidates.push(Path.join([value,"ffdec.bat"]));
        candidates.push(Path.join([value,"dist","ffdec.jar"]));
        candidates.push(Path.join([value,"dist","ffdec-cli.jar"]));
        candidates.push(Path.join([value,"ffdec.jar"]));
    }

    static function findOnPath(name:String) : String
    {
        var path = Sys.getEnv("PATH");
        if(path == null)
        {
            return null;
        }
        var windows = Sys.systemName() == "Windows";
        for(dir in path.split(windows ? ";" : ":"))
        {
            if(dir.length == 0)
            {
                continue;
            }
            var candidate = Path.join([dir,name]);
            if(FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate))
            {
                return candidate;
            }
            if(windows)
            {
                for(ext in [".exe",".bat",".cmd"])
                {
                    var withExt = candidate + ext;
                    if(FileSystem.exists(withExt) && !FileSystem.isDirectory(withExt))
                    {
                        return withExt;
                    }
                }
            }
        }
        return null;
    }

    static function runFfdec(ffdec:FfdecTool, args:Array<String>) : Int
    {
        if(ffdec.jar)
        {
            return run("java",["-Xmx2048m","-jar",ffdec.path].concat(args));
        }
        return run(ffdec.path,args);
    }

    static function ensureDirectory(path:String) : Void
    {
        if(FileSystem.exists(path))
        {
            return;
        }
        var parent = Path.directory(path);
        if(parent != null && parent.length > 0 && !FileSystem.exists(parent))
        {
            ensureDirectory(parent);
        }
        FileSystem.createDirectory(path);
    }

    static function copyDirectory(from:String, to:String) : Void
    {
        ensureDirectory(to);
        for(name in FileSystem.readDirectory(from))
        {
            var src = Path.join([from,name]);
            var dest = Path.join([to,name]);
            if(FileSystem.isDirectory(src))
            {
                copyDirectory(src,dest);
            }
            else
            {
                File.copy(src,dest);
            }
        }
    }

    static function deleteDirectory(path:String) : Void
    {
        if(!FileSystem.exists(path))
        {
            return;
        }
        for(name in FileSystem.readDirectory(path))
        {
            var child = Path.join([path,name]);
            if(FileSystem.isDirectory(child))
            {
                deleteDirectory(child);
            }
            else
            {
                FileSystem.deleteFile(child);
            }
        }
        FileSystem.deleteDirectory(path);
    }

    static function deleteDirectoryIfEmpty(path:String) : Void
    {
        if(FileSystem.exists(path) && FileSystem.isDirectory(path) && FileSystem.readDirectory(path).length == 0)
        {
            FileSystem.deleteDirectory(path);
        }
    }

    static function run(command:String, args:Array<String>) : Int
    {
        var process:Process = null;
        try
        {
            process = new Process(command,args);
        }
        catch(e:Dynamic)
        {
            Sys.println("  failed to run " + command + ": " + Std.string(e));
            return 1;
        }
        var code = process.exitCode();
        var stdout = process.stdout.readAll().toString();
        var stderr = process.stderr.readAll().toString();
        process.close();
        if(code != 0)
        {
            if(stdout.length > 0)
            {
                Sys.println(stdout);
            }
            if(stderr.length > 0)
            {
                Sys.println(stderr);
            }
        }
        return code;
    }

    static function removeDeviceFonts(path:String) : Void
    {
        if(!FileSystem.exists(path) || !FileSystem.isDirectory(path))
        {
            return;
        }
        for(name in FileSystem.readDirectory(path))
        {
            var file = Path.join([path,name]);
            if(FileSystem.isDirectory(file))
            {
                removeDeviceFonts(file);
                if(FileSystem.readDirectory(file).length == 0)
                {
                    FileSystem.deleteDirectory(file);
                }
                continue;
            }
            if(isDeviceFontFile(name))
            {
                FileSystem.deleteFile(file);
            }
        }
    }

    static function isDeviceFontFile(name:String) : Bool
    {
        var underscore = name.indexOf("_");
        if(underscore <= 0)
        {
            return false;
        }
        var fontName = Path.withoutExtension(name.substr(underscore + 1));
        fontName = StringTools.trim(StringTools.replace(fontName,"\x00","")).toLowerCase();
        return fontName == "arial" || fontName == "_sans" || fontName == "_serif" || fontName == "_typewriter";
    }
}

typedef FfdecTool = {
    var path:String;
    var jar:Bool;
}
