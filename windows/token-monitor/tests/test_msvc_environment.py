"""Synthetic installed-tool contract; never executes Windows tools or Cargo."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
SCRIPTS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SCRIPTS))
import build_scanner

class MsvcEnvironment(unittest.TestCase):
    def fixture(self,root):
        program=root/'Program Files (x86)';system=root/'Windows';installation=root/'Visual Studio/2022/Enterprise'
        tools=installation/'VC/Tools/MSVC/14.44.35207';binary=tools/'bin/Hostx64/x64';sdk=root/'Windows Kits/10/Lib/10.0.26100.0/um/x64';crt=tools/'lib/x64'
        paths=[program/'Microsoft Visual Studio/Installer/vswhere.exe',system/'System32/cmd.exe',installation/'VC/Auxiliary/Build/vcvarsall.bat',*(binary/name for name in ('link.exe','cl.exe','lib.exe')),sdk/'kernel32.lib',crt/'libcmt.lib']
        for path in paths:path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'synthetic tool or library')
        ambient={'ProgramFiles(x86)':str(program),'SystemRoot':str(system),'PATH':str(root/'Git/usr/bin')}
        initialized={'Path':str(root/'Git/usr/bin'),'LIB':str(sdk)+';'+str(crt),'INCLUDE':str(tools/'include'),'VCToolsInstallDir':str(tools),'WindowsSdkDir':str(root/'Windows Kits/10'),'GITHUB_TOKEN':'SYNTHETIC_MUST_NOT_FORWARD','OPENAI_API_KEY':'SYNTHETIC_MUST_NOT_FORWARD'}
        calls=[]
        def run(arguments,**kwargs):
            calls.append((arguments,kwargs))
            if isinstance(arguments,list)and arguments[0].endswith('vswhere.exe'):return subprocess.CompletedProcess(arguments,0,(str(installation)+'\r\n').encode('utf-8'),b'')
            output='\r\n'.join(f'{key}={value}'for key,value in initialized.items())+'\r\n'
            return subprocess.CompletedProcess(arguments,0,output.encode('utf-16le'),b'')
        return ambient,initialized,calls,run,binary,installation
    def test_installer_locator_and_real_toolset_precede_git_link_for_host_and_target(self):
        with tempfile.TemporaryDirectory(prefix='tm-msvc-')as temporary:
            ambient,_,calls,run,binary,installation=self.fixture(Path(temporary))
            result=build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',run)
            self.assertEqual(result['PATH'].split(';')[0],str(binary))
            self.assertEqual(result['CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER'],str(binary/'link.exe'))
            self.assertEqual(result['CC_x86_64_pc_windows_msvc'],str(binary/'cl.exe'))
            self.assertNotIn('GITHUB_TOKEN',result);self.assertNotIn('OPENAI_API_KEY',result)
            self.assertEqual(len(calls),2)
            self.assertIn('Microsoft.VisualStudio.Component.VC.Tools.x86.x64',calls[0][0])
            command=Path(ambient['SystemRoot'])/'System32/cmd.exe'
            setup=installation/'VC/Auxiliary/Build/vcvarsall.bat'
            expected=f'"{command}" /d /u /s /c "call "{setup}" x64 >nul && set"'
            self.assertEqual(calls[1][0],expected)
            self.assertEqual(calls[1][1]['executable'],str(command))
            self.assertIs(calls[1][1]['shell'],False)
            # Python's actual Windows serialization adds C-argv backslash quote
            # escapes, which cmd /s /c must not receive for the batch path.
            broken=subprocess.list2cmdline([str(command),'/d','/u','/s','/c',f'call "{setup}" x64 >nul && set'])
            self.assertIn('\\"',broken)
            self.assertNotIn('\\"',expected)
            command_body=expected.split(' /c ',1)[1]
            self.assertEqual(command_body[1:-1],f'call "{setup}" x64 >nul && set')
    def test_missing_installer_never_falls_back_to_bare_link_exe(self):
        with tempfile.TemporaryDirectory(prefix='tm-msvc-')as temporary:
            ambient,_,calls,run,_,_=self.fixture(Path(temporary))
            (Path(ambient['ProgramFiles(x86)'])/'Microsoft Visual Studio/Installer/vswhere.exe').unlink()
            with self.assertRaisesRegex(ValueError,'scanner_msvc_locator_unavailable'):build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',run)
            self.assertEqual(calls,[])
    def test_setup_failure_or_missing_sdk_libraries_cannot_issue_a_build_environment(self):
        with tempfile.TemporaryDirectory(prefix='tm-msvc-')as temporary:
            ambient,initialized,_,run,_,_=self.fixture(Path(temporary))
            initialized['LIB']=''
            with self.assertRaisesRegex(ValueError,'scanner_msvc_environment_incomplete'):build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',run)
            def failed(arguments,**kwargs):
                if isinstance(arguments,list)and arguments[0].endswith('vswhere.exe'):return run(arguments,**kwargs)
                return subprocess.CompletedProcess(arguments,1,b'',b'synthetic vcvars failure')
            with self.assertRaisesRegex(ValueError,'scanner_msvc_setup_failed'):build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',failed)
    def test_external_tool_directory_and_shell_expansion_path_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix='tm-msvc-')as temporary:
            ambient,initialized,_,run,binary,_=self.fixture(Path(temporary))
            initialized['VCToolsInstallDir']=str(Path(temporary)/'Git')
            with self.assertRaisesRegex(ValueError,'scanner_msvc_tool_path_invalid'):build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',run)
    def test_ambiguous_installer_and_missing_target_linker_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='tm-msvc-')as temporary:
            ambient,_,_,run,binary,installation=self.fixture(Path(temporary))
            def ambiguous(arguments,**kwargs):return subprocess.CompletedProcess(arguments,0,(str(installation)+'\r\n'+str(installation)+'\r\n').encode('utf-8'),b'')
            with self.assertRaisesRegex(ValueError,'scanner_msvc_installation_ambiguous'):build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',ambiguous)
            (binary/'link.exe').unlink()
            with self.assertRaisesRegex(ValueError,'scanner_msvc_tools_unavailable'):build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',run)
    def test_installer_shell_expansion_characters_cannot_be_interpreted(self):
        with tempfile.TemporaryDirectory(prefix='tm-msvc-')as temporary:
            ambient,_,_,run,_,_=self.fixture(Path(temporary)/'literal%NAME%')
            with self.assertRaisesRegex(ValueError,'scanner_msvc_setup_path_invalid'):build_scanner.msvc_environment(ambient,'x86_64-pc-windows-msvc',run)
    def test_ambient_flags_and_credentials_are_not_in_public_build_allowlist(self):
        self.assertNotIn('RUSTFLAGS',build_scanner.BUILD_ENV_KEYS)
        for name in ('GITHUB_TOKEN','OPENAI_API_KEY','HTTP_PROXY','HTTPS_PROXY','CARGO_ENCODED_RUSTFLAGS','LINK','CC','CXX'):
            self.assertNotIn(name,build_scanner.BUILD_ENV_KEYS)
        self.assertIn('ProgramFiles(x86)',build_scanner.BUILD_ENV_KEYS)

if __name__=='__main__':unittest.main()
