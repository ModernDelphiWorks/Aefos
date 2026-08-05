unit {{Name}}Unit;

interface

function Greeting: string;

implementation

uses
  System.SysUtils;

function Greeting: string;
begin
  Result := 'Hello from {{Name}}';
end;

end.
