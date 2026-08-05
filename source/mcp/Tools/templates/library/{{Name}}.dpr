library {{Name}};

uses
  System.SysUtils;

function Hello: Integer; stdcall;
begin
  Result := 42;
end;

exports
  Hello;

begin
end.
