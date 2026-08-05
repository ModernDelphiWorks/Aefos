unit Aefos.OTA.Terminal.UI.WelcomeAssets;

{ Auto-generated: 128x128 Aefos Terminal logo (PNG, transparent) embedded
  as base64 so the WelcomePane renders the mark without an external resource
  file. Source: assets\logo_terminal_transparent.png, downscaled 1024->128. }

interface

uses
  Vcl.Imaging.pngimage;

// Decodes the embedded logo. Returns nil-safe: on any failure APng is nil and
// Result is False, so the WelcomePane simply renders without the mark.
function TryLoadWelcomeLogo(out APng: TPngImage): Boolean;

// Raw base64 of the embedded PNG, for the WebView2 welcome to drop into an
// <img src="data:image/png;base64,..."> data URI (no temp file / no resource).
function WelcomeLogoBase64: string;

implementation

uses
  System.Classes, System.SysUtils, System.NetEncoding;

const
  LOGO_PNG_B64 =
    'iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMA' +
    'AA7DAcdvqGQAACiRSURBVHhe7Z0HXFNX+8cTLI7ieG0dVVsV3AMXKlOR4bYKyBJBcAMqruJCi7PWrbgndYHsvUdAdtgYNgIZJEAS' +
    'krDnff6fE7i8kGpr+6/Bvsn383nIvfeMXO755Tnn3HvOuQQAkAEAIkGKZOLu7t5PKgAJpqvwpQKQVKQCkHAcHR2lbQBJRtoIlHCk' +
    'VYCEIxWAhCOtAiQcqQAkHKkAJBxpN1DCkXoACQcVvlQAEgyqAqTdQAlGWgVIOEgAosf6kmFx/OGDg2tH9jK3/27LebFGCfefdhqh' +
    'hw2+VTuSgOwhjOjcZo4kXK0dMfhC7cjBF5gjBzvWjhiM9tEnbocqRgw5Jvh2yJ5OG7yrYsRYC8G3Yy0YQvvekP8NspkraN2mgkyF' +
    '9o2GBnW4hiJ1+FpRG58z3Kzb4obbjM8ZbjM+brjZ+NfDCQTCF3W9vwgPMDi9Zmn/wuY7/fNb38nkddQQ32ECYjYmIGZiAmIaJiCS' +
    'MQExBRMQkjABIQ4TEGIwASEKExDCMQEhBBMQAjEBwQ8TEHyAT/ACPsED+ARX4BNeAZ/wAviE58AnOAOf+BT4xMfAl7kP/H53gN/P' +
    'CfiyN4A/4Arwv76I8Qafx3jDTgN/hAPGG30U44071MGTt8NqpuzBambtxGrmb8NqFlt21Khvxmq0TTDuKgOMq/djR43Jqg7uFp0O' +
    '7g7NDq7t0g7uIbV27nHldu7pRW3ciwvauDcWtHEfzm/jvp7fzPFYUFvgM6/S7bfZOcZfhBj6UgADI2rGy5Y2+RNZAIQWAAIXgFgM' +
    'QMwFIOYAEDMAiGQAYjIAMQGAGAcgEwNAjAQghgEQQwCIAQAyfgAy3gBELwAZdwDiGwCiCwDxJQDxNwCiMwDxWafJPAaQeQDQ7y7A' +
    'V04AsjcABl4F+PpXgMG/AAw7C/DtzwCjTwB8bw+gcABg6j6AWTYAc3cCLNoKoG4BoG0KsNIQ4Ec9AOM1AFtWAOzUBtinCXBYHeCk' +
    'CsC5xQBXlADuKQH8tgDARwkgRRmgRAPgnRpApFJV2rXJ4Sqi10Ws9FXhDyKxF8pQ25iENgBiKYBMWHlK/6cpp/pfDtkw4PhLHblj' +
    'T3XlDjzVHbD3qe4Auwc6A2wf6AzYeU9XbtsdHTnLmzoDLK7rDth8U2eA8XVduc03deRM0LaTrpzJHR1kAzbe0ZHbeEdngIGT7oAN' +
    'd3TkDJx05Qzu6Q5Y76Q7YP09Xbn1Trpy6+7oyK110pVbea/bhul02jfINO7pjtK4pztW5aHQxi98qCs/756uvOI93amKD3RmzLin' +
    'qzj1gc68KQ91Fyk80VEd/0BHY/wDHc3xD3V1xj7UXTv2oe76sU91DcY+19089onOzh9erjg9IdTmxQxKQNR8PlRrAmSo1LXcnR5j' +
    'IHp9xEZfeIDhsYwf+r1vrSa0AhDjmez+lwONROP8r2M97paKr2I+masJkKla13pVMVBJNI5Y6Is7gbLZTQGEDgCZhIpq2bXHZ4uG' +
    'SxCDfWZRUpt1AaIX0dMJBEI/0QifHXHfCBqUJFCWYQIQy9ug//FHhqLhkobWt9bT0pS5TZVaAI9nR60RDf/siLsKGJTXcpXYDtAv' +
    'qChLNOzbJ/FDBsWxnw0urk8Z5UvZ3DNs6tVMvUUuvBT121VvFu3x/hY/vl375ujXZuVuflu5pPM/9nGD6m/iOpv8vH0FQNii4mei' +
    'YZ8dcQugf2F7jEwjgKxz3GnRMLmAkgNfswHkygGGJXCxEZtPjEHHh2nu/8+Uh7z6ub4A6j4A804XHsfT3NPPvk22Bni7HeCpXllO' +
    'rwz/JVyZ5G3M1QZIVK7MEA377Ii7CviqEMuQ4QDIXvPdIho29HXm5qEFAMOKAYYGMeoGG+4biY5/q7ZtyKRL9KpZbgDzXAFmHIm3' +
    'wdNcXJHyS4QlQJgFwN3Vv/cq/waOTHik8n4JAFmVUyz22/LibgR+ld+RIVMNIHPTz1w0DDWChj7OOf4fvxKPwQ5vlvYMGGfppTL1' +
    'bKnntMPpFwmTJw/Aj0/+ZtXQ09rJt66vpHjuXvx0bs80/xYOjrs/N18DIFmF/R5dItHwz4q4q4B+BVi6TBWA7HV/C9EwScVu3M05' +
    'ueoYJKmyS/tCAGIrfIRsAaQJBfBhDyCRCAWggUGSigQIoH++VACiIAFQ1KFPPYDYRNA/F9JkKlEV4COtArroFAAGiX3kAcTaBuif' +
    'h6XKsABkr0gFgNMtAEnwALIUSBMK4GagtAroAhdAgkp1n/QCxFb4iH7vIA3dCpa9Jm0D4OBtgESJ6Ab+iQAMD14bdPzCdXXR433I' +
    'wMTElKiysvKC4uKSXGRFJSWU4uKSvKKi4uzMTEqAh4fPGQMDy+miCT8VO/mbc95pACSo9o0HELMAsFSZCiQA7w8K4M5LD+MmAHib' +
    'nhWupL5uvGi4uLGxOaQGnwCjgtni5uZzTjT9p4AEkKMOEC8RHiC7SwDXA3o97ME57HhlVGzWu9foopZWsGruP32Jhk71Gb+9eHMc' +
    'nQuGYVhHR4fQeoLv4UIICYt8KprHn9EpAExCBJCFpcrQP14F4Dx56baNWc1GzgDCIknoosqJxhEHb+MSA3v80LvBCx/pARcGHvbi' +
    'het20Xz+CCSAbA0M4lSq+6wXIDb6ZWKpMjQA2ct/LACEicWeqeSsnHh0USn5he8OHzu1SDTO5yYmNjmZxxMAl1vTaTU10Nzc0lsI' +
    'XQLARVBYWFxJIBCGiOb1MezkL8/J6isBOIJ4Hwb1y8BSieUAsr94fvJ9gFt3Hx5v7cCAVc3GLl68JdahU6bb7UYfOHJy1oEDJ2cd' +
    'Puw4c8/BI4qnTl3Qee3qcaqoqKQcFbiwWhAKAMOgqza44XR/t2heHwN5gEx1gLd9VAWIrfARMmlYKrEMQObSJwvgP9FvE26ji/qe' +
    'weRduHLz7w8hM0wctCSg9uXm+Pr44TdpszVJ8NVMR0p/pYcgiwzfRp+4iWbRk6+/HjGm5H1pBe4J8BYB2k9ISkkRjf8xbMbdnJOp' +
    'gQTQBx5A3G0AmRSMTHwPIHvxz6uAc5dvrSgqo9LQBU1MzwrTWWumIBrnL7GzaJJTVafrln9T4zXZj2uk6MOxUnSvslJ8VWU115ll' +
    'Nf8xa6vyfaqV6m3a1iXXSy21r5ZYrbhStHXlLyXW634pUxXN8tmzVz+JVgVov6aGD8bGmxeIxv8Q6D4AEkCMJNwKFgqgGED2woe7' +
    'gV0Q3wRHnq1px4Db3AKvvf2PiUb4e4DMwmC+o0Fqk9+Q59VTRUP/iOVXsuQ2nCu1MD5f3qtQdXRWT62qYgsLvWcvAe17evvf6Bn3' +
    'Y9igKgAJQLkvqgAxDwjpl4yRiSUAsufcPlgFnLx0f0pMfkkSuoAZJWXUI2d+Xd4z/PbtR1OzsylPM3PeuaRnZrlkZr17nZ2d4+ob' +
    'HHFhco+BIp+MZdl/COYln1StODqCjN7Z0l36J0vnGh4vGmntWDKKQFCSfffuXXp3W6DLE6D9vIKiClRTiOYjChJAxhJMQjxAIkYm' +
    'FgDInvX4oAe45vzGKJdXC/6JGa4EwuARouH3nF+bNja1QEtbOzQ2t0JTSxugq52WRREoKCgNE43/Z5j5c9yesQC+u1p9aPr9iuWz' +
    'b1csX3idoauC7DJDd9klhs7qKyztdY7vhTeljI6+H2bgUGCy2bHIcOvZUuMl+4o3vHgT4d2zHYALoKWlFY4cObVS9DtFEQpAA4MY' +
    'VXYZelwiGv5ZEbsA4rEUYj6AzNmPVwGa+ju+Fz3WA+IqPZNJa/RMZqxYZzB93bpN000sts+Yo7p8lGjET0HPjbP3XFpTxphrlfrT' +
    'HzOVZj9gL1x0Gxlzodp15kKtq2yltU78xasd3+9ddaJMBXmB3jm499t/0ut+Y6PwlkV3NdDZ0gC4du3u78Y+ioIEkLYEg2jVagkQ' +
    'QBxGRnP/ZH7+cBXwj3CLM3R2aP3Dmf61jqJBfxcjR+i/zqHUwuxkodXm40Xmmx0LzE3Oluwyv1IuP3nyqqHZOXml3V6gSwBsNhfT' +
    '07P407bGHvnbikIBdPYCxCuArgUixIZMLEYmvgOQcXD9fAJ4zDVDjYjwFoD+D3kHR/vzTUZ7cU3H+PPNvvfmb1Jwqd406S5zy9S7' +
    'VJNJd2irZjvR1869RtNXdarQW3KuXF40u4+x3j5/iNkZqjXajo9P8cIFgN8ebm1tg/sPn9mKphPFRv7ynHQNSfEASADZADJHX/+p' +
    'a/zb3KMq6MU3JpnG1/r3fyKYNjKYP2lkcNOkEeGCKd+HNk2e4MmeLn+TtmjKnbJ52jdpe1UuvtedcSl3yvwbzBmajnTzVQ4VGkbu' +
    '8EnTtDadpU9ZdZSmf/mO/00QtkZwL9DZE2AyWY02Nvs0RdP1RFgFaABEqQgF8D/eCIzuFIDsic8ogL+A0YWqVysucH5eeZZusP5n' +
    'qtEGB9ay1SdZ64wcaJtMjzCMkVk4MIw2HWaYmjpUnTU/ybKycqBabnMot9h+km5uc55ltOPXip2qBo9WlpWWUvF2ABIA3hag0ej1' +
    'd+7c/+i0Lzv5u3PSlgBESYQHQALIApD9nFXAB5ixjTlhhR17l+LaHLRKx+9Q2pUmq2lJGrjOnqZpcohhtPkwc6apLXWW6QHqLLMj' +
    'NEXzkwzTTSeqPtiid3Sk9NeyijN47RbaozfQKQDcE+TnF3HRiDjRtAjkAVKFAuiDbqC4J4bIRGFktPCDuD3A2kMVbo0AYHuOHa96' +
    'hWOofZNluuISy2TtlSrDDeerNm50ZBibnGcZmR+jTTY8WDzZ8kT1WqtDVSuRWTrwV1mdrVNcf6t5pr5Tnbb+9TrtjTfqlhneq9Pe' +
    '9LRRc8OzVrXh60ganj5RMb0E0PkBLS0tHTGxiY8+tiKIUABLhR5A/AIQtwcgRmJkYhqAzE/iFcCyHaUbzt1vTDfZX2WjfJE3cYkT' +
    'S37lDdbElRdZEzc4dpqJI2Oq4U+lW4x/oupuPlA+Zpsje+zWC9hIAuHJEMWN3huMj0QfOXDR58cD5z1/PHTWbf3+s556No6v9Ryu' +
    'u1m88Q53rq2tbUEFLuwKdj0qRoLIzS2g/lHBoodB5KUAkSpVEiCAMIxMIAPI2L8SaxXwVzA+UK6+9RhrndWZ+pUb7cjmD54nFZDT' +
    'izAum11fU8PDeDw+8Go6rYbLg+am5q5ePwDeA+i8K9jZBmhra4cXL96Yin4PDmoDpCwBiFCt6pM2ACp88QkgBCMTU/peAFYO3B92' +
    'n+Av3nmMvQjZ7hOcxTtPsRfZnOUrHXJqnm57B5usrrtrPOVdltCt/xm428fpqv67HgzxGs6evagoeg44B+UfKCIPECEJjUBiMJZK' +
    'TASQOfC8zwRgdaJ6wZYjTJsdx2uWWB2qUtt5hKu28xhHeecxgfIOR4HKvl8FaiaOXDXfoMTsngXc6da7SlaksDs38P2uASJdAqDT' +
    'K5oNDMwmiJ4HDvIAwipATRIEEISRCQkAMvtffLY2gLpCxXinM7yk80e5Hrq69CmWu1kTzffy5A33suTNdleoW+xl/rplZ9WkTZsK' +
    'Rmzdxxxpalc52uogTdHKvmTKjsMF8uv35I89dMhBo76+vgMVIF7APZ/0idIlgV4CwHsAMTFx7qLn2BPkAVKQB1CrKhe7AMT93kBi' +
    'IEYmxAPI7P3t8wlA/v2PrDyAuEAA7eWlu7fsqza22FNpZmpbsWnTbubuTTb0LZttGcbmdjRTK7tKs60HGVt3n6i6anmwzHTnMer6' +
    'zfYMnaDQuLeo8Lp/zT3u73cW+H+t6/5PN6JpCgqLCz7WBUTYTb07p1MAkuAB/DAyIRZAZt/nqwKUlNJkzVeV2ZivLtooGvaJyFVU' +
    'MHk9CxNtl5SU0f38go5cv37f+PHjF8vv33+2HH3eu/d09ePHv22Njo51QQ2+znS9PYanp98t0S/BsZv6eE7yUoDwPmoEilsAqYQY' +
    'ABmbp5/NA/x/efTkuTUqtM4uXWcB8vmCtm3b9s0XjStKZCTpeVfaXl4APRdwcfE8KRofgdoASUsAwjs9gPi7gaLHPidE3y4PYP3Y' +
    'UjTsS4FMzkjEf/14lZ+anhUmGu9DjFZQGFVeTuPjXkB4S7hHuyEoKPyu6K8c7waGS8J4ANwDEHZ+mQI4fPjUoqYew75xHj369Ear' +
    's/Nre9H0PclIz47/5pvJQ/H4B6c8ndvZDRRWAeL3AGIVgA9GJpCQB3j5RQrg2W9u+5nMqlZGRWULsoqKyrbU9Bz68OEKf2W00Veh' +
    'oZF+DDqzkU5nNdNozGY6jdlMozJbmBVVrankHMbg7+YJF8BC2E16rIRuBYerVqExgZ/0FPIfQ+wCcG2JFXYDj/mdEg37EtDUNBo8' +
    'f77BhCVLDOWXLDeU19IymUQYPLm7sP4KipM1v1eeu2Hi3GkrJyrPXTlx8Zwf5TWVTSaKznI6Mcl1Q74WQIhylfiXuUOFL04B9HvK' +
    'eURAq3//mhwvGiap3Jkd+7xyBYD74iI30bDPjrg9QL8zmWsJgWhJ9zrot/bYR5+RSworRtgoRalyW/KWATjOcBP/RFhxCwA9EiXe' +
    'qUpDPQGiU3GVrMb2OaIRJAWtkbvneswrojJ0AV7Ny8sWew8A0QcCIMhud5lDfMRuIEQAEO8y6mT2+zoQ1HfMQivJo6lgyIb1smE9' +
    'Pv/cCB+0CR849ldt+LCPH0OfHzKCiA37j8WEs/OvzY64FLCI2UDTAQhYzKy3kv/4w6LPSl8IADHQ7NVSmbvMCkIwAMEPgHCHA8Tr' +
    '5VziFRqHeInGkUF2gcaROU/n9DtH53x1utP6/0znDDhJ5ww8QefIHaVxhtrTOMN+onO+OcxgjzhAZ486wGB/Z0fnfL+XzplgQ+fI' +
    'W9M5k3fROdN3MtkztzPYs7bT2XO20tnzLWmcBVsY7MUWdLbaZjp7qSmdrWNMZ68wpLPXGDDY6/Xo7I0bGGzj9XS2+RoGe+sqBnvH' +
    'CjrbZjmDvV+HzrbXorOPL2WwTy9hsC9o0NmX1RnsG+oM9h01JvuBKoP9RJXBfqbKYL9QYVS/VKWzXVUY1R4qdLaPaiUnUr0RSpYD' +
    'FOoCeCwsKzQff0tN9PqIjb4SAGK0gvko2dPpF2VuMWnEJx1AfAEg4wwgg7/a5SFAvwcAX90HkL0NIOsEMOAGwKBrAIOuAMhdAhj6' +
    'C8Dw8wAjzgKMOgMwxhHg+1MAExwAJh8FmGYPMPMwgOJBgHkHAJQOACzeB6C6B0DDBkBzN4DODoDV2wB+tATQ3wJgbA5gtgnA0gRg' +
    'uxGA9UYAO32An9YDHFsHcGotwPlVAJdXANzUBbinDfBYC+C5FsDrZQDumgDemgB+mgBBSwHCNAGilgLELAWIXQoQrCpod19Izb46' +
    'OxZNefvkaeSfhb4UAM4YNNHWwmP+gK0hugMsg3XkrMK05cyDtAeY+mnLmftpy5kFaskZ+mkjG2YYpD1M3097mL6X9jADX61vf/TS' +
    'FtpqL+3R6wO1Rq8J1Bq3xldoE1Z0mXag1ngtL+1p2oFayGYhW9ppc1T9tJEtWNxpixcEaqku8NNWWxCopbbAV2vpXE+tJXPctLXm' +
    'uGmvmOWptXymm/aaWZ5aa6Z5aulPddNeP81Ty2Cap5bxJE8tUwU3bWRbJnlqIdvWZVYKLto7FFy0rRXctLdPcF22dvzF/98k13+S' +
    'L0EAUvoQqQAkHKkAJBypACScvhRATm6BeQWT+aa4tPz6zcePR4uG/xO8dndXKi0tv0ZjMDzLyst9qXSGN53O8C0pLfN46eUlfCWN' +
    'RNNXAqDk52/t+YiUyWKl/dN3wuKTk7X4gtrWnt/TE3d3n3miaSSOvhCA+eHDcjU8HlO0QMhpaftF4/5/oNHpEShfNByjupr9Pjc3' +
    '16+oqMSnvLzcu7CwMMzV1fUH0TQSR18IgJKX9zNe6Pn5BcyGhgbhQDo+X1B59OjRjz53Dw4PV3mXl7clr6DANptC2ZNXkGdbUFRk' +
    'W1BQsONtQoIOPpjCy8trVHx8vDmXyxWKrKOjA2Lj4m75BQYaR0VFmYVHRZkZGm7/Bs83IiJClZKXZ5mfn2/97l2eLYVC2ZuXl2eb' +
    'm5u/rSvf33kmX9/gmVlZ7ywo+fm7c3JzrXNzC2xyc/OtUTq0n1dQZBsSGftJi0T1KeIeFYzq3br6+jpUMPUNDa3Xrl3TpNJowsUg' +
    'EZS8vAu/S/PSa0wFixXT3iEcpf1R2Gx2hp+f3+jIyJjl+LGes3R7kpadveTWy5dDaXT62w8E96K6mv0uODKy+6FVUVHJFXzI+B+R' +
    'Q8m/1Ps/6c3LW9hQ718E3e9A7InvJWxI8C1O96ihz4a4PUA5lXoXv0CFhYWv0DG/wMBN6FeKqG9oqBNtnNEZ9FA8TW1dHVQwmc1M' +
    'FquFVYlG7VS01tbW4sFQWVXl5uHjoyMQCKC1tbV7cCafzxeu8snj8wGFeXv7q9LpdGc8HRq2x2BUtFdUMNsqKtBnRXt9XX13vmwO' +
    'p0xTU/Or1MxMLfxYe3s7oPhMJqsFnQ+TVdnCZLJamSxWK6uysj05mXyi5//Rk4s7WxQv78aq7u7EBNe3tv/uMfBdk/bUhybtuQ93' +
    'pf3O+/yjiFMA3t7ekxobG4UD7urq6wX3799Ho2OEFBcXx+EXtqio6AF+/PXr19MbGhqEx7k1NdwjR44s//rrr8coKSmNn6mkhBZu' +
    'GuPg4LCCh0q2UyCNLi4us86c+UW1srJSuJInagP4+vofvHTp0sL7jx+rP3jwYMGbN29m19XVoQnD0NDQ2Ort7WtvY2endOzYqUXH' +
    'Tp1SPnLixOJLl66uf19aKlz6BREcHKGRm5t/At9PSEr2JhAIY8eOnfSDgsLM8TNmzJ8wbdrciTNnKo23tt4/7eLFex+cio6w397h' +
    'fc4G4PxOgDOWHXkgsvbQNaMO+nXjDv6tfUV/feWzv4I4BUCvoLvhF6+goNDD399/PIlEmpyQnj4hNDzcprm5WegGUIE8d3UVrq0T' +
    'E/Nfd87j8Vj5hfkOVCr1BJVKdWAwGA4VFRXHi0pKfubX1nI60zZAUFCQMC2bzS7E01IoFI2e5xIaGqrW0tI5+LO6WrhO/wchk8kP' +
    '8DzSM3N2x8XF7cL3+XxBGY/Hu8Nms2+wWKwbLFbVDS6Xe6OysvqAf0TER5e63/5Ty5wDBwGst7c6b9vccPXcHoCTW9t6vUf5vHFH' +
    '8QXjDrajY9nAnsf/ccQlgKioKLW2tjbhhUP1cktLS0NTU1NrY2NjG/psam6ub21t655IUVpe7oLSxcTFrcYv+KdCIpGE6/5VVVWV' +
    '4cfS09NRY66b0NBQLVwAHA43/2MTZItKSpzwPEpKS+2tra1HFReXvMePfYzaurq6yJj4JaL5IdYebvU0te9ot7St+k5zgvNA663t' +
    'DfusOig9y+G4YUfxSaN2jrMj/G8IgFlZSRK9SH8EKhx/f//pMTExi/BjbA6Hm5qa6paTk+NPoVD8s3OyA3JysgOyc3IC0D4llxKQ' +
    'lZ3t49XZhujHZrNL8LQpKSm9BODt76/R3Nw5rbuyqgoJ4IMUFBTcwvPIy+t8Z/G2bdvGxsfHX8zOzg7MysoJzszMDM3IzAxNz8gI' +
    'zM7OoaC2B4JKo0eK5qd6oW72wpMASw4DrDjaEbz6cEfIBqv2NuvtANYWbevweHs2dhQfMGznOFv+D3iAxJSUVfhFrKmpEQQFB5+L' +
    'jolxIMXGnox5+xZ9noqNjT0ZHBx8tKCoKBmPy6qq8na8eFGhsalzDT4ej1993NERtcZRvYhW4EQ2uMf2oB5fO6iazS7G80pJ6e0B' +
    'Ll26OaWGxxOWVENDY72np+/S0aNHy40ZM+brMWM687ty5c6ECiYzE88jNTUVH8qOhm6ja4YKB30nbl+dOnVmo0AgEHqxyqqqop7f' +
    'iZA/0+Q2+QLAgv08itp+QelSW37p0q28bL3NGBibdaTi8TZv7CjeJhTAZ/YAjp9ZADONjPpzuNwc/CJmZGVdFo3TE9RIq6uvF15A' +
    '9MfD23v1+9LSSDx9Q2NjM5vDoXG4XCqXx6VyuVxqTU0NDW3z+DxGUUnJ866sBrI5nB4C6O0BUAHm5RdGdefb0NDO5XIZNTU1dDaX' +
    'S2ezuQyBoLa7G8Dl1giuXn04IjAwQoFVWUnn8/kMgUBQzufzy7k8XnkNn1/G5fKojY2NNXia/IIi/FyETHGqn/vddYDRx+sSCEa9' +
    'x/+rGdS7rt8BsGFTs3Cg7PqN7SUb9Nq4t/Zh/+5GYGxi4l78gjBZrJoTJzpfCf9HpGdmueNp6Ax6zMEjJxVL3r/P+8jM7F6UU6mZ' +
    'XdkMoNJoXWuDA4RFRa0Q+RrCr9fvzCoqfp+KT+j8GNVsTmVoKEkPpXH1CFgmGi4KOksqvSLl6t1nve40fnuuIWD4LYBRRyp7rX+M' +
    'mPpjzRxVc4Clxm2pqEewbGNbyTK9lrp/fS/AIzBQ2T8oZIdPYKDt41evPultYOeu3v0hIDR0b1hExCHS27eb0DGNVYYjPX38LWLj' +
    '4k5GkUhnIiKizkREkU4ji+r6jCCRTgeGhxt1ZUN84+61xccv4GhgSJjdgwcvPyy8kTMHv37tbhoRRToZEUU6j1t0dMy5KFLsmYDg' +
    'UBuHy7cm4dFdXPxGR8fEH4l5G/9zTEz8z1Gk2NPR0W/PdqW7QIpNOOXpE2pCGKmJqqZejD7BWTzmp6qPXoMF+rwF6psaNdBytCqG' +
    'dYqaxg0qBMLnKxshn1sAUr5wpAKQcKQCkHD+TQJA6/spnKoNkD/ZGD3FoSV4/kH+5IUnm6fNsG8Nn3W87dXio7XCe+9q++vnzdvX' +
    'TlK1a4/RtG26uWsXCO+nL9/e8HSVZZ3wfYVrzRtebNzWtBNtG+zgr9TfWncfbRse5H+jZ94SYWQG8wy3NU8zMGvsvi2NekwmJi2x' +
    '2za1dj+2ttnRoLRNv8Ht98vI/0sQmwDQBUILMBv1MLTf8xi+jR/HzRG+QunRS5xmn6nRVDhZ16h4oUlH07Fs4Gx7wZopB5p48w81' +
    'O6gfqhXe7l1g16A/e2/jezXbtjWq2xs6Vu4XTEPHNXfU5S7fVl+pb9doanQQYKUlXzhDeZWFYJvuJl4u2l5jW//dOssm+NGsgbph' +
    'R8OBlSZ13X3zDRaNZqs3Nkcb6TUk7LcENIOJsMOifqWFQSO7pwAcCY4yRkbQDzf3LjMidFmP42gfD3dH2wTo50gQo5jEJYApDzjK' +
    'E580Hv3+Lu+n7+8I7CfeEdgr3OPZK9wT2Cs41dtPcaq3n+ZUb69wo95e4Xr9EYVrtUcnXq49MvFS7dEffm12mHyldibKR/l45WiF' +
    'Y/zKOffqhC+ImGHHXTNtr6Ba5UDHeQ0bvvCVcvOsBatn765nz9/VnLJoZ50PvvK3mhU3QHsHL15ra13TGpu6VA1zjvB9AstMOZYa' +
    'xmxh91F3V814bUtOxhpL3i+65q2gZVgTjf8Pyw35lKWGgotrDZpy9fXrhd7G1Lxu+cb1dTQ8DsJCR6C6Uwc7Zbui8Zi1buMxW93G' +
    'Y3bItJA1H9uv1Xx8HzLN5uMHNBuP7VdvPr5PpfH4XuXGY3vV20/u1mj8aE/hHwcVvjgEgL7DCKAfMveuT2SajqSv0OvbOg1t/9dQ' +
    'wSFDcQhd5zjfnjr2h5/YuVPOc8ah/Wn7ecsmW/PLZu+pezTHpkp4q1Zxp2D1jJ3sUK2DgjWLdtbErzjIFw7+WGRR7a9qVbVSY2vN' +
    'OlVL9mlVM65w7MESs2oTZRN2DNrW3sIZt8ycK/zVK+tzn6gbsBPQ9spN/JXLDGrIS43rtFZtbrBdrc/PNjKi9NffzF+0Zn1tlaF+' +
    'i6+RPvcnFBd5A0dH+KrTSF2G73/ANDtNU7M73v+eB/jHcASZ6ccY3yIXinaROGba1n8307ZpsuIOuvBVMzMdob/KQZqw0Nce5Iwz' +
    'P4wJF2RYsV0oBOH/qmbPHrJ+G1s4LUvTEgZ2hQkLT2fPfwdp6FuzhJ5mhSH/GyNb6O7br93CGYcKCwlUf3P1GBO95qmmpg1j8fB/' +
    'Df86AUj5Z5EKQML5XxZAX/1fffW9f4svUQD+gYE3Q8LDjW7fvv1tZGRkSGJi4k0ymfxDcGgwKSUlxTI4OGK+t7evc1xc3P7ycuZM' +
    'Hx+fkKCgIGEDEOHp7XshMDAQPacf5+/v7xQVFXWpsLBQISIiIjo9PcsEzQdIIZNJWVlZP8bExG2Li0u44BcYsqmgoMg8LCwstLi4' +
    'WM3fP/Cn+PjkJU5OTnZOTk72JSUlU16+fH01ikS6GZeUJOxupqWljY+IiHibnU0xCwmPtKZQKJN9fHx+ePTgwdFHjx7tS01NXRwW' +
    'Fv48ICDwTkJC0vXU1NQPP4/oS740AcQkJir6+vqCr79vUmJiilFhUREkJiVSExLIi2JiYyApKelxWFjY6oTEBPjt+fOctLQ0WXd3' +
    '9wxfX9/1eB7PnjlnpJDJwOFwxj15+qTY2dk5q7i4eFZaWhrk5FAuv3jxyo7FqoLi4uLj7u7u15OTU8DNze1idXX1GF8/vxQajTbI' +
    'w8MjNjw88ujBgwcPHz169GhGRsYGV1cXhp+fP/j7B5mh7wkKCloYEhICubm5eq5v3nh7efnahYdHGRw5fOT46dM/X8zLy1N5/vx5' +
    'DolEglevXqGVx8XXuv9UxP3KmD+DQqHMzMsrUsnJyVFtwLBxoRERG928vLQxDBsUFRVlHBYdrV5Io40rKytbFRoauhilSc1KVU5L' +
    'S+ueTxD99q1yTEycMY/Hk09JSVmanJymzeVyf4iJizNOSkpVRgUcEh6+KTQ0dHpRUdHImLi4LegTDZHPzMwU5kkmZ6gBwODAwEBd' +
    '/6AgNCxNtri4WDUxMVUd/fJRnIKCghGZme+EffbIyMjFISHhxhiGDXH18DDw9fXVQsejouLm5uTk6oWFhX3S62nFzpfmAaSIGXHd' +
    'CPqr1GGdd/q6zq97bLyzs/Pvhkh1xREux47ion30KyeRSAPRNob9flQN8igoTs//ncP544kYXXn3WsqVQqH07/KiA4uKOgdvoDj/' +
    'mh/Wl3ai6II+evJo37lz5w45OzuvTSKTTaKio6gREaRVPj4+tsnJybTS0lJjF5dXl0NDQ6MyMjI0X75+ed3f3y8rLilpeVBQAJoD' +
    'eNrT0z3G19/3EplMnh8SEszw8fE5gGGYnKuLS1xdXd3sN2/ehPn5+T3HMEy+qalpmaur6/6QkOBgf3//ragB6ufvlxEWFvYYPy8P' +
    'Dw/n4OCgfCaTOSM0PNQ/LCzsRlhY5O7wiPDy0lLqFheX17HBwYE3i4qKJoWFhZbl5eXtcHFxWR4YGPz6+fPfogIDA4W3qb84vjQB' +
    'AMDXt2/fvrB9+/Ydz58774tLSNiTlJwECUlJx7y8fK5RaTTg1NRscXd3CwgLD4O0tEy9Z8+eefr6+baXlJVZZ2dnQ3h4+M+hYaGP' +
    '4+LiVoeFhanHxcdBaFjYTdRr8PcPgISEhMN+AQHXfH39t2IYNhYA9F65vHoWHR2d4+3tfYFEemsTFR0FT548jsPPK/bt22DUmAsN' +
    'Df3G3cPL87cXLw5SqVSr8vJyiIqK2hIUHOSckJCwlkwmT4siRQE5jXwpKChUL5pEgpDQEMjJyfnDt4f2GV+aABCoQRYSEaILAP2o' +
    'VOpwFos1Kzc3dwJywS4eHsrx8fFDMAwb09TUJE/l84enp6ePDQwMnFdUxBz59u1bZRKJNDgvL29MWlra1ywWS47F5c5C3cD09PQJ' +
    'qMDfvXs3qaSkBE0gHYLyZLPZQ2gYNig8OlwTue/ExMRv+E1NCsnJyd1vMU9KSpoYExMjfF8ASltVVTUYw7ChFAplcXBw8ID09Pyx' +
    'WVlZcqgqIpFI8yIiIhTev38/rLm5eToATEfxe/2TXwpfogCkiBGpACQcqQAkHKkAJBypACQcqQAkHKkAJBypACQcqQAkHKkAJByp' +
    'ACQcqQAkHHEvFCnlC0PqASQcqQAkHPTMXSoACUbqASQcqQAkHKkAJBypACSb/wMSCD6rrJhN3gAAAABJRU5ErkJggg==';

function TryLoadWelcomeLogo(out APng: TPngImage): Boolean;
var
  LBytes: TBytes;
  LStream: TBytesStream;
begin
  APng := nil;
  try
    LBytes := TNetEncoding.Base64.DecodeStringToBytes(LOGO_PNG_B64);
    LStream := TBytesStream.Create(LBytes);
    try
      APng := TPngImage.Create;
      APng.LoadFromStream(LStream);
      Result := True;
    finally
      LStream.Free;
    end;
  except
    on E: Exception do
    begin
      FreeAndNil(APng);
      Result := False;
    end;
  end;
end;

function WelcomeLogoBase64: string;
begin
  Result := LOGO_PNG_B64;
end;

end.
