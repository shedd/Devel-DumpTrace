
{
  package Abc::Def::Ghi;

  sub jkl {
    42;
  }

}

{
  package Abc::Ghi::Jkl;

  sub mno {
    19;
  }

}

package Abc::Def;
Abc::Def::Ghi::jkl();
Abc::Ghi::Jkl::mno();

