unit {{Name}}Tests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSampleTest = class
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure TestPasses;
    [Test]
    [TestCase('Sum 1+2', '1,2,3')]
    [TestCase('Sum 3+4', '3,4,7')]
    procedure TestSum(const A, B, Expected: Integer);
  end;

implementation

procedure TSampleTest.Setup;
begin
end;

procedure TSampleTest.TearDown;
begin
end;

procedure TSampleTest.TestPasses;
begin
  Assert.AreEqual(4, 2 + 2);
end;

procedure TSampleTest.TestSum(const A, B, Expected: Integer);
begin
  Assert.AreEqual(Expected, A + B);
end;

initialization
  TDUnitX.RegisterTestFixture(TSampleTest);

end.
