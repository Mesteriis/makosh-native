#!/usr/bin/env python3
"""Actual Mach-O relocation tests using only owned synthetic fixture binaries."""
import subprocess, tempfile, unittest, plistlib, importlib.util
from unittest.mock import patch
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class RuntimeBundleTests(unittest.TestCase):
    def fixture(self, root):
        deps=root/'deps'; deps.mkdir()
        (deps/'base.c').write_text('int base(void){return 40;}\n')
        (deps/'outer.c').write_text('extern int base(void); int outer(void){return base()+2;}\n')
        app=root/'Synthetic.app'; (app/'Contents/MacOS').mkdir(parents=True)
        (root/'main.c').write_text('#include <stdio.h>\nextern int outer(void); int main(void){printf("%d",outer());return 0;}\n')
        subprocess.run(['clang','-dynamiclib',str(deps/'base.c'),'-Wl,-install_name,'+str(deps/'libbase.dylib'),'-o',str(deps/'libbase.dylib')],check=True,capture_output=True)
        subprocess.run(['clang','-dynamiclib',str(deps/'outer.c'),str(deps/'libbase.dylib'),'-Wl,-install_name,'+str(deps/'libouter.dylib'),'-o',str(deps/'libouter.dylib')],check=True,capture_output=True)
        exe=app/'Contents/MacOS/Synthetic'
        subprocess.run(['clang',str(root/'main.c'),str(deps/'libouter.dylib'),'-o',str(exe)],check=True,capture_output=True)
        return deps,app,exe
    def testRelocatedBundleRunsWithOriginalDependenciesUnavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); deps,app,exe=self.fixture(root)
            result=subprocess.run(['python3',str(ROOT/'scripts/bundle-runtime.py'),'--bundle',str(app),'--allow-root',str(deps)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            deps.rename(root/'hidden-deps')
            subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
            result=subprocess.run([str(exe)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr); self.assertEqual(result.stdout,'42')
            self.assertTrue((app/'Contents/Frameworks/libbase.dylib').is_file())
    def testSeparateHelperRunsWithOriginalDependenciesUnavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); deps,app,exe=self.fixture(root)
            helper=app/'Contents/Helpers/ProtocolWorker';helper.parent.mkdir()
            subprocess.run(['clang',str(root/'main.c'),str(deps/'libouter.dylib'),'-o',str(helper)],check=True,capture_output=True)
            result=subprocess.run(['python3',str(ROOT/'scripts/bundle-runtime.py'),'--bundle',str(app),'--allow-root',str(deps)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            deps.rename(root/'hidden-deps')
            subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
            result=subprocess.run([str(helper)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,'42')
            subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    def testUnreviewedDependencyIsRejectedBeforeChangingExecutable(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); deps,app,exe=self.fixture(root); before=exe.read_bytes()
            result=subprocess.run(['python3',str(ROOT/'scripts/bundle-runtime.py'),'--bundle',str(app),'--allow-root',str(root/'unrelated')],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0); self.assertEqual(exe.read_bytes(),before)
    def staged(self, root, value):
        root.mkdir()
        deps, app, exe = self.fixture(root)
        (deps/'outer.c').write_text('extern int base(void); int outer(void){return base()+'+str(value-40)+';}\n')
        subprocess.run(['clang','-dynamiclib',str(deps/'outer.c'),str(deps/'libbase.dylib'),'-Wl,-install_name,'+str(deps/'libouter.dylib'),'-o',str(deps/'libouter.dylib')],check=True,capture_output=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.makosh.synthetic.packaging','CFBundleExecutable':'Synthetic','CFBundlePackageType':'APPL'}))
        subprocess.run(['python3',str(ROOT/'scripts/bundle-runtime.py'),'--bundle',str(app),'--allow-root',str(deps)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
        deps.rename(root/'hidden-deps')
        return app
    def publisher(self):
        spec=importlib.util.spec_from_file_location('publisher',ROOT/'scripts/publish-app-bundle.py')
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module
    def testConsecutiveFreshStagesReplaceBundleWithRelocatedDependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); destination=root/'Synthetic.app'; publisher=self.publisher()
            for value in (42,43):
                stage=self.staged(root/str(value),value)
                publisher.publish(stage,destination)
                result=subprocess.run([str(destination/'Contents/MacOS/Synthetic')],check=True,capture_output=True,text=True)
                self.assertEqual(result.stdout,str(value))
                subprocess.run(['codesign','--verify','--deep','--strict',str(destination)],check=True,capture_output=True)
    def testInvalidStagePreservesPreviousBundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); destination=root/'Synthetic.app'; publisher=self.publisher()
            publisher.publish(self.staged(root/'first',42),destination)
            stage=self.staged(root/'second',43)
            (stage/'Contents/Info.plist').write_bytes(b'invalid')
            with self.assertRaises(Exception): publisher.publish(stage,destination)
            self.assertEqual(subprocess.check_output([str(destination/'Contents/MacOS/Synthetic')]),b'42')
    def testFailedPublicationRestoresPreviousBundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); destination=root/'Synthetic.app'; publisher=self.publisher()
            publisher.publish(self.staged(root/'first',42),destination)
            stage=self.staged(root/'second',43); original=publisher.os.replace
            def failing(source,target):
                if source == stage: raise OSError('Synthetic publication failure')
                return original(source,target)
            with patch.object(publisher.os,'replace',side_effect=failing):
                with self.assertRaises(OSError): publisher.publish(stage,destination)
            self.assertEqual(subprocess.check_output([str(destination/'Contents/MacOS/Synthetic')]),b'42')
if __name__=='__main__': unittest.main()
