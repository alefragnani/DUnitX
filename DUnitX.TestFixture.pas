{***************************************************************************}
{                                                                           }
{           DUnitX                                                          }
{                                                                           }
{           Copyright (C) 2013 Vincent Parrett                              }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           http://www.finalbuilder.com                                     }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit DUnitX.TestFixture;

interface

uses
  DUnitX.TestFramework,
  DUnitX.InternalInterfaces,
  DUnitX.WeakReference,
  DUnitX.Generics,
  Rtti;

{$I DUnitX.inc}

type
  TDUnitXTestFixture = class(TWeakReferencedObject, ITestFixture, ITestFixtureInfo)
  class var
    FRttiContext : TRttiContext;
  private
    FTestClass : TClass;
    FName : string;
    FNameSpace : string;
    FDescription : string;
    FEnabled : boolean;
    FTests : IList<ITest>;
    FTestInfos : IList<ITestInfo>;
    FSetupMethod            : TTestMethod;
    FSetupFixtureMethod     : TTestMethod;
    FTearDownMethod         : TTestMethod;
    FTearDownFixtureMethod  : TTestMethod;
    FFixtureInstance : TObject;
    FTestInOwnThread : boolean;
    FSetupFixtureMethodName: string;
    FSetupMethodName: string;
    FTearDownMethodName: string;
    FTearDownFixtureMethodName: string;
    FChildren : ITestFixtureList;
  protected
    //uses RTTI to buid the fixture & tests
    procedure GenerateFixtureFromClass;
    function GetEnabled: Boolean;
    procedure SetEnabled(const value: Boolean);

    function GetName: string;
    function GetNameSpace : string;
    function GetFullName : string;
    function GetDescription : string;
    function GetTests: IEnumerable<ITest>;
    function ITestFixtureInfo.GetTests = ITestFixtureInfo_GetTests;
    function ITestFixtureInfo_GetTests : IList<ITestInfo>;
    function GetTestClass : TClass;
    function GetSetupMethod : TTestMethod;
    function GetSetupFixtureMethod : TTestMethod;
    function GetTearDownMethod : TTestMethod;
    function GetTearDownFixtureMethod : TTestMethod;
    function GetTestInOwnThread : boolean;
    function GetSetupFixtureMethodName: string;
    function GetSetupMethodName: string;
    function GetTearDownMethodName: string;
    function GetTearDownFixtureMethodName: string;

    function GetTestCount : cardinal;
    function GetActiveTestCount : cardinal;

    function GetChildren: ITestFixtureList;
    function GetHasChildren : boolean;
  public
    constructor Create(const AName : string; const AClass : TClass);
    destructor Destroy;override;
    class constructor Create;


  end;

implementation

uses
  TypInfo,
  {$IFDEF MSWINDOWS}
    {$if CompilerVersion < 23 }
      Windows,
    {$else}
      WinAPI.Windows, // Delphi XE2 (CompilerVersion 23) added scopes in front of unit names
    {$ifend}
  {$ENDIF}
  SysUtils,
  DUnitX.Test,
  DUnitX.Utils;

{ TDUnitXTestFixture }

constructor TDUnitXTestFixture.Create(const AName : string; const AClass : TClass);
var
  i : integer;
begin
  FTestClass := AClass;
  FTests := TDUnitXList<ITest>.Create;

  i := LastDelimiter('.',AName);
  if i <> 0 then
  begin
    FNameSpace := Copy(AName,1,i -1);
    FName := Copy(AName,i+1,Length(AName));
  end
  else
  begin
    FName := AName;
    FNameSpace := AName;
  end;


  FEnabled := True;

  //TODO: Constructor doing "work" makes this harder to test and handle errors if the class isn't of the correct structure
  GenerateFixtureFromClass;
end;

destructor TDUnitXTestFixture.Destroy;
begin
  if FFixtureInstance <> nil then
    FFixtureInstance.Free;

  FTests := nil;
  inherited;
end;

{$IFDEF MSWINDOWS}
procedure PatchCodeDWORD(Code: PDWORD; Value: DWORD);
// Self-modifying code - change one DWORD in the code segment
var
  RestoreProtection, Ignore: DWORD;
begin
  if VirtualProtect(Code, SizeOf(Code^), PAGE_EXECUTE_READWRITE,
    RestoreProtection) then
  begin
    Code^ := Value;
    VirtualProtect(Code, SizeOf(Code^), RestoreProtection, Ignore);
    FlushInstructionCache(GetCurrentProcess, Code, SizeOf(Code^));
  end;
end;

const
  vmtRunnerIndex = System.vmtAutoTable;


{$ENDIF}


procedure TDUnitXTestFixture.GenerateFixtureFromClass;
var
  rType : TRttiType;
  methods : TArray<TRttiMethod>;
  method : TRttiMethod;
  attributes : TArray<TCustomAttribute>;
  attribute : TCustomAttribute;
  meth : TMethod;
  newTest : ITest;

  fixtureAttrib : TestFixtureAttribute;
  testCases : TArray<TestCaseAttribute>;
  testCaseAttrib : TestCaseAttribute;
  testEnabled : boolean;

begin
  rType := FRttiContext.GetType(FTestClass);
  System.Assert(rType <> nil);
  FFixtureInstance := FTestClass.Create;

  //If the fixture class was decorated with [TestFixture] then use it for the description.
  fixtureAttrib := nil;
  if rType.TryGetAttributeOfType<TestFixtureAttribute>(fixtureAttrib) then
    FDescription := fixtureAttrib.Description;


  methods := rType.GetMethods;
  for method in methods do
  begin
    meth.Code := method.CodeAddress;
    meth.Data := FFixtureInstance;

    attributes := method.GetAttributes;
    if Length(attributes) > 0 then
    begin
      for attribute in attributes do
      begin
        //first check if the method is our setup or teardown.
        if attribute.ClassType = SetupAttribute then
        begin
          FSetupMethod := TTestMethod(meth);
          FSetupMethodName := method.Name;
        end
        else if attribute.ClassType = SetupFixtureAttribute then
        begin
          FSetupFixtureMethod := TTestMethod(meth);
          FSetupFixtureMethodName := method.Name;
        end
        else if attribute.ClassType = TearDownAttribute then
        begin
          FTearDownMethod := TTestMethod(meth);
          FTearDownMethodName := method.Name;
        end
        else if attribute.ClassType = TearDownFixtureAttribute then
        begin
          FTearDownFixtureMethod := TTestMethod(meth);
          FTearDownFixtureMethodName := method.Name;
        end
        else if attribute.ClassType = TestInOwnThreadAttribute then
          FTestInOwnThread := true
        //TODO: Should add tests to the list even though they aren't enabled.
        else if ((attribute.ClassType = TestAttribute)) or
                ((attribute.ClassType <> TestAttribute) and (method.Visibility = TMemberVisibility.mvPublished) and (not method.HasAttributeOfType<TestAttribute>)) then
        begin

          if attribute.ClassType = TestAttribute then
          begin
            testEnabled := TestAttribute(attribute).Enabled;
            //find out if the test fixture has test cases.
            testCases := method.GetAttributesOfType<TestCaseAttribute>;

            if Length(testCases) > 0 then
            begin
              for testCaseAttrib in testCases do
              begin
                newTest := TDUnitXTestCase.Create(FFixtureInstance, Self, testCaseAttrib.Name, method.Name, method, testEnabled, testCaseAttrib.Values);
                newTest.Enabled := testEnabled;
                FTests.Add(newTest);
              end;
            end
            else
            begin
              newTest := TDUnitXTest.Create(Self, method.Name, TTestMethod(meth),testEnabled);
              FTests.Add(newTest);
            end;
          end
          else
          begin
            newTest := TDUnitXTest.Create(Self, method.Name, TTestMethod(meth),True);
            FTests.Add(newTest);
          end;



        end;
      end;
    end
    else if method.Visibility = TMemberVisibility.mvPublished then
    begin
      newTest := TDUnitXTest.Create(Self,method.Name,TTestMethod(meth),true);
      FTests.Add(newTest);
    end;
  end;
end;

function TDUnitXTestFixture.GetActiveTestCount: cardinal;
begin
  //TODO: Return the active count, currently fudged to be the count.
  Result := GetTestCount;
end;

function TDUnitXTestFixture.GetChildren: ITestFixtureList;
begin
  if FChildren = nil then
    FChildren := TTestFixtureList.Create;
  result := FChildren;
end;

function TDUnitXTestFixture.GetDescription: string;
begin
  result := FDescription;
end;

function TDUnitXTestFixture.GetEnabled: Boolean;
begin
  result := FEnabled;
end;

function TDUnitXTestFixture.GetFullName: string;
begin
  if FName <> FNameSpace then
    result := FNameSpace + '.' + FName
  else
    Result := FName;
end;

function TDUnitXTestFixture.GetHasChildren: boolean;
begin
  result := (FChildren <> nil) and (FChildren.Count > 0);
end;

function TDUnitXTestFixture.GetName: string;
begin
  result := FName;
end;

function TDUnitXTestFixture.GetNameSpace: string;
begin
  result := FNameSpace;
end;

function TDUnitXTestFixture.GetSetupFixtureMethod: TTestMethod;
begin
  result := FSetupFixtureMethod;
end;

function TDUnitXTestFixture.GetSetupFixtureMethodName: string;
begin
  result := FSetupFixtureMethodName;
end;

function TDUnitXTestFixture.GetSetupMethod: TTestMethod;
begin
  result := FSetupMethod;
end;

function TDUnitXTestFixture.GetSetupMethodName: string;
begin
  result := FSetupMethodName;
end;

function TDUnitXTestFixture.GetTearDownFixtureMethod: TTestMethod;
begin
  result := FTearDownFixtureMethod;
end;

function TDUnitXTestFixture.GetTearDownFixtureMethodName: string;
begin
  result := FTearDownFixtureMethodName;
end;

function TDUnitXTestFixture.GetTearDownMethod: TTestMethod;
begin
  result  := FTearDownMethod;
end;

function TDUnitXTestFixture.GetTearDownMethodName: string;
begin
  result := FTearDownMethodName;
end;

function TDUnitXTestFixture.GetTestClass: TClass;
begin
  result := FTestClass;
end;

function TDUnitXTestFixture.GetTestCount: cardinal;
begin
  Result := FTests.Count;
end;

function TDUnitXTestFixture.GetTestInOwnThread: boolean;
begin
  result := FTestInOwnThread;
end;

function TDUnitXTestFixture.GetTests: IEnumerable<ITest>;
begin
  result := FTests;
end;

function TDUnitXTestFixture.ITestFixtureInfo_GetTests: IList<ITestInfo>;
var
  test : ITest;
begin
  //TODO: Need to test that this isn't accessed between updates to FTests.
  if FTestInfos = nil then
  begin
    FTestInfos := TDUnitXList<ITestInfo>.Create;
    for test in FTests do
      FTestInfos.Add(test as ITestInfo);
  end;
  result := FTestInfos;
end;


procedure TDUnitXTestFixture.SetEnabled(const value: Boolean);
begin
  FEnabled := value;
end;

class constructor TDUnitXTestFixture.Create;
begin
  FRttiContext := TRttiContext.Create;
end;

end.

