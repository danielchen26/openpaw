/// Declares a fieldless enum whose JSON representation is a fixed string per
/// variant, together with `as_str`, `Display`, `FromStr` and an `ALL` table.
///
/// Keeping the wire literal next to the variant means the serde attribute and
/// `as_str` can never drift apart.
macro_rules! wire_enum {
    (
        $(#[$meta:meta])*
        pub enum $name:ident {
            $( $(#[doc = $doc:literal])* $variant:ident = $wire:literal ),+ $(,)?
        }
    ) => {
        $(#[$meta])*
        #[derive(
            Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord,
            serde::Serialize, serde::Deserialize,
        )]
        pub enum $name {
            $(
                $(#[doc = $doc])*
                #[serde(rename = $wire)]
                $variant,
            )+
        }

        impl $name {
            /// Every variant, in declaration order.
            pub const ALL: &'static [$name] = &[ $( $name::$variant ),+ ];

            /// The JSON string this variant serializes to.
            pub const fn as_str(&self) -> &'static str {
                match self {
                    $( $name::$variant => $wire, )+
                }
            }
        }

        impl ::core::fmt::Display for $name {
            fn fmt(&self, f: &mut ::core::fmt::Formatter<'_>) -> ::core::fmt::Result {
                f.write_str(self.as_str())
            }
        }

        impl ::core::str::FromStr for $name {
            type Err = $crate::ParseEnumError;

            fn from_str(s: &str) -> ::core::result::Result<Self, Self::Err> {
                match s {
                    $( $wire => Ok($name::$variant), )+
                    other => Err($crate::error::ParseEnumError::new(stringify!($name), other)),
                }
            }
        }
    };
}

pub(crate) use wire_enum;
