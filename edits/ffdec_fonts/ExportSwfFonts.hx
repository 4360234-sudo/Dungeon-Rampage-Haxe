package;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.Process;
import sys.io.File;

class ExportSwfFonts
{
    static function main() : Void
    {
        var args = Sys.args();
        var ffdec = "ffdec";
        var i = 0;
        while(i < args.length)
        {
            var arg = args[i];
            if((arg == "--ffdec" || arg == "-ffdec") && i + 1 < args.length)
            {
                ffdec = args[i + 1];
                break;
            }
            i++;
        }
        var projectRoot = findProjectRoot();
        var librariesPath = Path.join([projectRoot,"generated_swf_libraries.xml"]);
        var outRoot = Path.join([projectRoot,"Resources","ffdec_fonts"]);
        var count = 0;
        var failed = 0;
        var exported = new Map<String,Bool>();

        ensureDirectory(outRoot);

        var xml = Xml.parse(File.getContent(librariesPath));
        for(node in xml.elementsNamed("project"))
        {
            for(library in node.elementsNamed("library"))
            {
                var swfPath = library.get("path");
                var id = library.get("id");
                if(swfPath == null || id == null || !StringTools.endsWith(swfPath.toLowerCase(),".swf"))
                {
                    continue;
                }

                var result = exportSwf(ffdec,projectRoot,outRoot,swfPath,id,exported);
                if(result == true) count++;
                else if(result == false) failed++;
            }
        }

        var projectXmlPath = Path.join([projectRoot,"project.xml"]);
        var projectXml = Xml.parse(File.getContent(projectXmlPath));
        for(node in projectXml.elementsNamed("project"))
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
                    id = getProjectLibraryId(swfPath);
                }

                var result = exportSwf(ffdec,projectRoot,outRoot,swfPath,id,exported);
                if(result == true) count++;
                else if(result == false) failed++;
            }
        }

        Sys.println("Done. Exported font folders for " + count + " SWF(s)" + (failed > 0 ? ", failed: " + failed : "") + ".");
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

    static function exportSwf(ffdec:String,projectRoot:String,outRoot:String,swfPath:String,id:String,exported:Map<String,Bool>) : Null<Bool>
    {
        var source = Path.normalize(Path.join([projectRoot,swfPath]));
        if(!FileSystem.exists(source))
        {
            return null;
        }

        var key = Path.normalize(swfPath) + "|" + id;
        if(exported.exists(key))
        {
            return null;
        }
        exported.set(key,true);

        var outDir = Path.normalize(Path.join([outRoot,id]));
        deleteDirectory(outDir);
        ensureDirectory(outDir);
        Sys.println("Export fonts: " + swfPath);
        var code = run(ffdec,["-onerror","ignore","-format","font:ttf","-export","font",outDir,source]);
        if(code == 0)
        {
            removeDeviceFonts(outDir);
            deleteDirectoryIfEmpty(outDir);
            return true;
        }

        Sys.println("  ffdec failed with code " + code);
        return false;
    }

    static function getProjectLibraryId(swfPath:String) : String
    {
        return Path.withoutExtension(Path.withoutDirectory(swfPath));
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
        var process = new Process(command,args);
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
