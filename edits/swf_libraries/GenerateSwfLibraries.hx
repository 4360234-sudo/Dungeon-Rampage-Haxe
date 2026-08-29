import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class GenerateSwfLibraries
{
    static function main() : Void
    {
        var projectRoot = findProjectRoot();
        var libraries = SwfLibraries.listResourceLibraries(projectRoot);
        var outputPath = Path.join([projectRoot,SwfLibraries.outputName]);
        File.saveContent(outputPath,SwfLibraries.toXml(libraries));
        Sys.println("Generated " + libraries.length + " SWF libraries in " + outputPath);
    }

    static function findProjectRoot() : String
    {
        var cwd = Sys.getCwd();
        while(cwd != null && cwd.length > 0)
        {
            if(FileSystem.exists(Path.join([cwd,"project.xml"])))
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
}
