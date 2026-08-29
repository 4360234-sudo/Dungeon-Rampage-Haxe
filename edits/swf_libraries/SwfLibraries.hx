import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class SwfLibraries
{
    public static var outputName = "generated_swf_libraries.xml";

    public static function listResourceLibraries(projectRoot:String) : Array<{path:String, id:String, preload:Bool, generate:Bool}>
    {
        var preloadRules = readRules(Path.join([projectRoot,"edits","swf_libraries","preload.txt"]));
        var generateRules = readRules(Path.join([projectRoot,"edits","swf_libraries","generate.txt"]));
        var resourcesRoot = Path.join([projectRoot,"Resources"]);
        var libraries = [];
        if(!FileSystem.exists(resourcesRoot) || !FileSystem.isDirectory(resourcesRoot))
        {
            return libraries;
        }
        var paths = [];
        walkSwfs(resourcesRoot,paths);
        paths.sort(function(a,b)
        {
            var na = Path.normalize(a).split("\\").join("/");
            var nb = Path.normalize(b).split("\\").join("/");
            var cmp = Reflect.compare(na.toLowerCase(),nb.toLowerCase());
            return cmp != 0 ? cmp : Reflect.compare(na,nb);
        });
        for(absolute in paths)
        {
            var relative = toProjectPath(projectRoot,absolute);
            libraries.push({
                path: relative,
                id: libraryId(relative),
                preload: matchesAny(relative,preloadRules),
                generate: matchesAny(relative,generateRules)
            });
        }
        return libraries;
    }

    public static function libraryId(relativePath:String) : String
    {
        var path = relativePath.split("\\").join("/");
        if(StringTools.startsWith(path,"./"))
        {
            path = path.substr(2);
        }
        var out = new StringBuf();
        out.add("ax4_swf_");
        for(i in 0...path.length)
        {
            var c = path.charAt(i).toLowerCase();
            var code = c.charCodeAt(0);
            if((code >= 97 && code <= 122) || (code >= 48 && code <= 57))
            {
                out.add(c);
            }
            else
            {
                out.add("_");
            }
        }
        var id = ~/_{2,}/g.replace(out.toString(),"_");
        while(StringTools.endsWith(id,"_"))
        {
            id = id.substr(0,id.length - 1);
        }
        return id;
    }

    public static function toXml(libraries:Array<{path:String, id:String, preload:Bool, generate:Bool}>) : String
    {
        var lines = [
            '<?xml version="1.0" encoding="utf-8"?>',
            "<project>"
        ];
        for(library in libraries)
        {
            lines.push('\t<library path="' + library.path + '" id="' + library.id + '" preload="' + boolAttr(library.preload) + '" generate="' + boolAttr(library.generate) + '" />');
        }
        lines.push("</project>");
        return lines.join("\n") + "\n";
    }

    static function boolAttr(value:Bool) : String
    {
        return value ? "true" : "false";
    }

    static function toProjectPath(projectRoot:String, absolute:String) : String
    {
        var root = Path.removeTrailingSlashes(Path.normalize(projectRoot)).split("\\").join("/");
        var path = Path.normalize(absolute).split("\\").join("/");
        if(StringTools.startsWith(path.toLowerCase(),root.toLowerCase() + "/"))
        {
            return path.substr(root.length + 1);
        }
        return path;
    }

    static function walkSwfs(dir:String, out:Array<String>) : Void
    {
        for(name in FileSystem.readDirectory(dir))
        {
            var path = Path.join([dir,name]);
            if(FileSystem.isDirectory(path))
            {
                walkSwfs(path,out);
                continue;
            }
            if(StringTools.endsWith(name.toLowerCase(),".swf"))
            {
                out.push(path);
            }
        }
    }

    static function readRules(path:String) : Array<String>
    {
        if(!FileSystem.exists(path))
        {
            return [];
        }
        var rules = [];
        for(line in File.getContent(path).split("\n"))
        {
            var trimmed = StringTools.trim(line);
            if(trimmed.length == 0 || StringTools.startsWith(trimmed,"#"))
            {
                continue;
            }
            rules.push(trimmed);
        }
        return rules;
    }

    static function matchesAny(path:String, rules:Array<String>) : Bool
    {
        for(rule in rules)
        {
            if(matchesRule(path,rule))
            {
                return true;
            }
        }
        return false;
    }

    static function matchesRule(path:String, rule:String) : Bool
    {
        var pattern = new StringBuf();
        pattern.add("^");
        for(i in 0...rule.length)
        {
            var c = rule.charAt(i);
            switch(c)
            {
                case "*":
                    pattern.add(".*");
                case "?":
                    pattern.add(".");
                default:
                    if("\\.^$+()[]{}|".indexOf(c) >= 0)
                    {
                        pattern.add("\\");
                    }
                    pattern.add(c);
            }
        }
        pattern.add("$");
        return new EReg(pattern.toString(),"").match(path);
    }
}
